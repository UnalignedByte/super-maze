//
//  MazeRenderer.m
//  Super Maze
//
//  Created by Rafał Grodziński on 19.08.2014.
//  Copyright (c) 2014 UnalignedByte. All rights reserved.
//

#import "MazeRenderer.h"

#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#import <simd/simd.h>
#import "METLTransforms.h"

#import "Uniforms.h"
#import "Model.h"
#import "Super_maze-Swift.h"


@interface MazeRenderer ()

@property (nonatomic, strong) UIView *rendererView;

@property (nonatomic, strong) dispatch_semaphore_t renderSemaphore;

@property (nonatomic, strong) id<MTLDevice> device;
@property (nonatomic, strong) id<MTLLibrary> library;
@property (nonatomic, strong) id<MTLCommandQueue> queue;

@property (nonatomic, strong) id<MTLRenderPipelineState> pipeState;
@property (nonatomic, strong) id<MTLDepthStencilState> depthState;

@property (nonatomic, strong) MTLRenderPassDescriptor *passDescriptor;
@property (nonatomic, assign) MTLViewport viewport;

//Render Data
@property (nonatomic, assign) Uniforms *uniforms;
@property (nonatomic, strong) id<MTLBuffer> uniformsBuffer;

@property (nonatomic, strong) Model *mazeModel;
@property (nonatomic, strong) Model *ballModel;

@end


@implementation MazeRenderer

#pragma mark - Initialization
- (instancetype)initWithMaze:(Maze *)maze_ rendererView:(UIView *)rendererView_
{
    self = [super init];
    if(self == nil)
        return nil;
    self.rendererView = rendererView_;
    //Create Basic Rendering Stuff
    self.device = MTLCreateSystemDefaultDevice();
    self.library = [self.device newDefaultLibrary];
    self.queue = [self.device newCommandQueue];
    
    //Create Render Pipeline
    MTLRenderPipelineDescriptor *pipeDesc = [MTLRenderPipelineDescriptor new];
    pipeDesc.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
    [pipeDesc setDepthAttachmentPixelFormat:MTLPixelFormatDepth32Float];
    pipeDesc.sampleCount = 4;
    
    id<MTLFunction> vertProg = [self.library newFunctionWithName:@"default_vert"];
    pipeDesc.vertexFunction = vertProg;
    id<MTLFunction> fragProg = [self.library newFunctionWithName:@"default_frag"];
    pipeDesc.fragmentFunction = fragProg;
    
    self.pipeState = [self.device newRenderPipelineStateWithDescriptor:pipeDesc error:nil];
    
    //Pass Descriptor
    self.passDescriptor = [MTLRenderPassDescriptor renderPassDescriptor];
    
    //Create multisampled color attachement for pass descriptor
    self.passDescriptor.colorAttachments[0].loadAction = MTLLoadActionClear;
    self.passDescriptor.colorAttachments[0].storeAction = MTLStoreActionMultisampleResolve;
    self.passDescriptor.colorAttachments[0].clearColor = MTLClearColorMake(0.2, 0.2, 0.2, 1.0);
    
    MTLTextureDescriptor *multisampledTextureDesc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                                       width:rendererView_.frame.size.width
                                                                                                      height:rendererView_.frame.size.height
                                                                                                   mipmapped:NO];
    multisampledTextureDesc.textureType = MTLTextureType2DMultisample;
    multisampledTextureDesc.sampleCount = 4;
    id<MTLTexture> multisampledTexture = [self.device newTextureWithDescriptor:multisampledTextureDesc];
    self.passDescriptor.colorAttachments[0].texture = multisampledTexture;
    
    //Create depth buffer attachement for pass descriptor
    MTLTextureDescriptor *depthTextureDesc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float
                                                                                                width:rendererView_.frame.size.width
                                                                                               height:rendererView_.frame.size.height
                                                                                            mipmapped:NO];
    depthTextureDesc.textureType = MTLTextureType2DMultisample;
    depthTextureDesc.sampleCount = 4;
    id<MTLTexture> depthTexture = [self.device newTextureWithDescriptor:depthTextureDesc];
    self.passDescriptor.depthAttachment.texture = depthTexture;
    self.passDescriptor.depthAttachment.loadAction = MTLLoadActionClear;
    self.passDescriptor.depthAttachment.storeAction = MTLStoreActionDontCare;
    self.passDescriptor.depthAttachment.clearDepth = 1.0;
    
    //Create Depth Buffer State
    MTLDepthStencilDescriptor *depthDesc = [[MTLDepthStencilDescriptor alloc] init];
    depthDesc.depthCompareFunction = MTLCompareFunctionLess;
    depthDesc.depthWriteEnabled = YES;
    self.depthState = [self.device newDepthStencilStateWithDescriptor:depthDesc];
    
    //Viewport
    self.viewport = {0.0, 0.0, rendererView_.frame.size.width, rendererView_.frame.size.height, 0.0, 1.0};
    
    //Render Semaphore
    self.renderSemaphore = dispatch_semaphore_create(3);
    
    //Initialize Uniforms
    self.uniforms = (Uniforms *)malloc(sizeof(Uniforms));
    self.uniformsBuffer = [self.device newBufferWithLength:sizeof(Uniforms) options:0];
    
    CGFloat aspectRatio = rendererView_.frame.size.width/rendererView_.frame.size.height;
    self.uniforms->projectionMatrix = METL::perspective_fov(65.0, aspectRatio, 0.1, 1500.0);
    
    simd::float3 eye = {0.0, 300.0, -300.0};
    simd::float3 center = {0.0, 0.0, 0.0};
    simd::float3 up = {0.0, 1.0, 0.0};
    self.uniforms->viewMatrix = METL::lookAt(eye, center, up);
    
    [self update];
    
    //Load Assets
    self.mazeModel = [[Model alloc] initMazeModelWithDevice:self.device maze:maze_];
    self.ballModel = [[Model alloc] initBallModelWithDevice:self.device diameter:10.0];
    
    return self;
}


- (void)dealloc
{
    free(self.uniforms);
}


#pragma mark - Properties
- (void)setBallPosition:(CGPoint)ballPosition_
{
    _ballPosition = ballPosition_;
    
    //self.ballModel.modelMatrix = METL::translate(ballPosition_.x, 5.0, ballPosition_.y);
    self.ballModel.ballPosition = ballPosition_;
}


#pragma mark - Control
- (void)redraw
{
    //Wait for available command buffer
    dispatch_semaphore_wait(self.renderSemaphore, DISPATCH_TIME_FOREVER);
    
    //Create Command Buffer
    id<MTLCommandBuffer> commandBuffer = [self.queue commandBuffer];
    
    //Get Drawable
    id<CAMetalDrawable> drawable = [(CAMetalLayer *)self.rendererView.layer nextDrawable];
    self.passDescriptor.colorAttachments[0].resolveTexture = drawable.texture;
    
    //Create Command Encoder
    id<MTLRenderCommandEncoder> encoder = [commandBuffer renderCommandEncoderWithDescriptor:self.passDescriptor];
    [encoder setViewport:self.viewport];
    [encoder setDepthStencilState:self.depthState];
    [encoder setFrontFacingWinding:MTLWindingClockwise];
    [encoder setCullMode:MTLCullModeBack];
    
    //Draw models
    [self drawModel:self.mazeModel encoder:encoder];
    [self drawModel:self.ballModel encoder:encoder];
    
    //Commit and show stuff
    [encoder endEncoding];
    [commandBuffer presentDrawable:drawable];
    
    __weak MazeRenderer *welf = self;
    [commandBuffer addCompletedHandler:^(id<MTLCommandBuffer> commandBuffer) {
        dispatch_semaphore_signal(welf.renderSemaphore);
    }];
    
    [commandBuffer commit];
}


- (void)update
{
    Uniforms *uniformsBuffer = (Uniforms *)[self.uniformsBuffer contents];
    memcpy(uniformsBuffer, self.uniforms, sizeof(Uniforms));
}


#pragma mark - Internal Control
- (void)drawModel:(Model *)model_ encoder:(id<MTLRenderCommandEncoder>)encoder_
{
    [encoder_ setRenderPipelineState:self.pipeState];
    
    [encoder_ setVertexBuffer:model_.vertexBuffer      offset:0 atIndex:0];
    [encoder_ setVertexBuffer:model_.colorBuffer       offset:0 atIndex:1];
    [encoder_ setVertexBuffer:model_.modelMatrixBuffer offset:0 atIndex:2];
    [encoder_ setVertexBuffer:self.uniformsBuffer      offset:0 atIndex:3];
    
    [encoder_ drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:model_.vertexCount];
}

@end
