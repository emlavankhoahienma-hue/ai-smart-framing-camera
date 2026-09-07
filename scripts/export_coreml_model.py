#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Export Aesthetic Framing Model to CoreML (.mlmodel / .mlpackage)
Loads trained weights from scripts/AestheticFramingModel_weights.npz
"""
import os
import sys
import numpy as np

if sys.platform == "win32":
    try:
        sys.stdout.reconfigure(encoding="utf-8")
        sys.stderr.reconfigure(encoding="utf-8")
    except Exception:
        pass

WEIGHTS_FILE = os.path.join("scripts", "AestheticFramingModel_weights.npz")
MLMODEL_OUT = "AestheticFramingModel.mlmodel"

def export():
    print(f"📦 Đang nạp trọng số đã huấn luyện từ {WEIGHTS_FILE}...")
    if not os.path.exists(WEIGHTS_FILE):
        print(f"❌ Không tìm thấy file {WEIGHTS_FILE}! Hãy chạy train_aesthetic_framing_net.py trước.")
        sys.exit(1)
        
    data = np.load(WEIGHTS_FILE)
    
    import coremltools as ct
    from coremltools.models.neural_network import NeuralNetworkBuilder
    from coremltools.models.utils import save_spec
    
    input_features = [('image', ct.models.datatypes.Array(3, 64, 64))]
    output_features = [
        ('target_coords', ct.models.datatypes.Array(2)),
        ('suggested_zoom', ct.models.datatypes.Array(1)),
        ('scene_probs', ct.models.datatypes.Array(6)),
        ('rule_probs', ct.models.datatypes.Array(3))
    ]
    
    builder = NeuralNetworkBuilder(input_features, output_features)
    builder.set_pre_processing_parameters(image_input_names=['image'], image_scale=1.0/255.0)
    
    # Conv1: 3 -> 24, k=4, s=4
    w1 = data['w_conv1'].reshape(3, 4, 4, 24).transpose(1, 2, 0, 3)
    b1 = data['b_conv1']
    builder.add_convolution('conv1', kernel_channels=3, output_channels=24, height=4, width=4,
                            stride_height=4, stride_width=4, border_mode='valid', groups=1,
                            W=w1, b=b1, has_bias=True, input_name='image', output_name='act1_pre')
    builder.add_activation('relu1', 'RELU', 'act1_pre', 'act1')
    
    # Conv2: 24 -> 48, k=2, s=2
    w2 = data['w_conv2'].reshape(24, 2, 2, 48).transpose(1, 2, 0, 3)
    b2 = data['b_conv2']
    builder.add_convolution('conv2', kernel_channels=24, output_channels=48, height=2, width=2,
                            stride_height=2, stride_width=2, border_mode='valid', groups=1,
                            W=w2, b=b2, has_bias=True, input_name='act1', output_name='act2_pre')
    builder.add_activation('relu2', 'RELU', 'act2_pre', 'act2')
    
    # Conv3: 48 -> 96, k=2, s=2
    w3 = data['w_conv3'].reshape(48, 2, 2, 96).transpose(1, 2, 0, 3)
    b3 = data['b_conv3']
    builder.add_convolution('conv3', kernel_channels=48, output_channels=96, height=2, width=2,
                            stride_height=2, stride_width=2, border_mode='valid', groups=1,
                            W=w3, b=b3, has_bias=True, input_name='act2', output_name='act3_pre')
    builder.add_activation('relu3', 'RELU', 'act3_pre', 'act3')
    
    # Conv4: 96 -> 96, k=4, s=4
    w4 = data['w_conv4'].reshape(96, 4, 4, 96).transpose(1, 2, 0, 3)
    b4 = data['b_conv4']
    builder.add_convolution('conv4', kernel_channels=96, output_channels=96, height=4, width=4,
                            stride_height=4, stride_width=4, border_mode='valid', groups=1,
                            W=w4, b=b4, has_bias=True, input_name='act3', output_name='act4_pre')
    builder.add_activation('relu4', 'RELU', 'act4_pre', 'act4')
    
    # Dense FC: 96 -> 128
    builder.add_flatten('flatten', mode=1, input_name='act4', output_name='flat_feat')
    w_fc = data['w_fc'].T
    b_fc = data['b_fc']
    builder.add_inner_product('fc', W=w_fc, b=b_fc, input_channels=96, output_channels=128,
                              has_bias=True, input_name='flat_feat', output_name='fc_pre')
    builder.add_activation('relu_fc', 'RELU', 'fc_pre', 'fc_feat')
    
    # Head coords: 128 -> 2 (target_x, target_y)
    builder.add_inner_product('fc_coords', W=data['w_coords'].T, b=data['b_coords'],
                              input_channels=128, output_channels=2, has_bias=True,
                              input_name='fc_feat', output_name='coords_pre')
    builder.add_activation('sig_coords', 'SIGMOID', 'coords_pre', 'target_coords')
    
    # Head zoom: 128 -> 1
    builder.add_inner_product('fc_zoom', W=data['w_zoom'].T, b=data['b_zoom'],
                              input_channels=128, output_channels=1, has_bias=True,
                              input_name='fc_feat', output_name='zoom_pre')
    builder.add_activation('sig_zoom', 'SIGMOID', 'zoom_pre', 'suggested_zoom')
    
    # Head scene: 128 -> 6
    builder.add_inner_product('fc_scene', W=data['w_scene'].T, b=data['b_scene'],
                              input_channels=128, output_channels=6, has_bias=True,
                              input_name='fc_feat', output_name='scene_pre')
    builder.add_softmax('softmax_scene', input_name='scene_pre', output_name='scene_probs')
    
    # Head rule: 128 -> 3
    builder.add_inner_product('fc_rule', W=data['w_rule'].T, b=data['b_rule'],
                              input_channels=128, output_channels=3, has_bias=True,
                              input_name='fc_feat', output_name='rule_pre')
    builder.add_softmax('softmax_rule', input_name='rule_pre', output_name='rule_probs')
    
    save_spec(builder.spec, MLMODEL_OUT)
    size_kb = os.path.getsize(MLMODEL_OUT) / 1024.0
    print(f"✅ Xuất thành công {MLMODEL_OUT} ({size_kb:.1f} KB)!")

if __name__ == "__main__":
    export()
