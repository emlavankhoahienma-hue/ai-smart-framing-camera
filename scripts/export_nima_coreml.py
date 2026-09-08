import os
import sys
import urllib.request
import numpy as np

WEIGHTS_URL = "https://cdn.jsdelivr.net/gh/idealo/image-quality-assessment@master/models/MobileNet/weights_mobilenet_aesthetic_0.07.hdf5"
WEIGHTS_PATH = os.path.join(os.path.dirname(__file__), "weights_mobilenet_aesthetic_0.07.hdf5")
OUTPUT_MLPACKAGE = "NIMAAestheticScorer.mlpackage"
OUTPUT_MLMODEL = "NIMAAestheticScorer.mlmodel"

def ensure_weights():
    if not os.path.exists(WEIGHTS_PATH) or os.path.getsize(WEIGHTS_PATH) < 1000000:
        print(f"Downloading NIMA weights from {WEIGHTS_URL}...")
        urllib.request.urlretrieve(WEIGHTS_URL, WEIGHTS_PATH)
    print(f"Weights ready at {WEIGHTS_PATH} ({os.path.getsize(WEIGHTS_PATH)} bytes)")

def build_model():
    import tensorflow as tf
    from tensorflow.keras.applications.mobilenet import MobileNet
    from tensorflow.keras.layers import Dropout, Dense
    from tensorflow.keras.models import Model

    base_model = MobileNet(
        input_shape=(224, 224, 3),
        alpha=1.0,
        include_top=False,
        pooling="avg",
        weights=None
    )
    x = Dropout(0.75, name="dropout_1")(base_model.output)
    x = Dense(10, activation="softmax", name="dense_1")(x)
    model = Model(inputs=base_model.input, outputs=x, name="NIMA_MobileNet_Aesthetic")
    model.load_weights(WEIGHTS_PATH, by_name=True)
    return model

def convert_to_coreml(keras_model):
    import coremltools as ct
    print("Converting Keras model to CoreML (mlprogram)...")
    
    image_input = ct.ImageType(
        name="image",
        shape=(1, 224, 224, 3),
        scale=1.0 / 127.5,
        bias=[-1.0, -1.0, -1.0],
        color_layout=ct.colorlayout.RGB
    )
    
    try:
        mlmodel = ct.convert(
            keras_model,
            inputs=[image_input],
            convert_to="mlprogram",
            compute_units=ct.ComputeUnit.ALL
        )
    except Exception as e:
        print(f"Direct Keras conversion failed ({e}). Trying via SavedModel...")
        import tempfile
        with tempfile.TemporaryDirectory() as tmpdir:
            sm_path = os.path.join(tmpdir, "saved_model")
            keras_model.save(sm_path)
            mlmodel = ct.convert(
                sm_path,
                inputs=[image_input],
                convert_to="mlprogram",
                compute_units=ct.ComputeUnit.ALL
            )
    
    # Metadata
    mlmodel.author = "Google Research / idealo (AVA Dataset)"
    mlmodel.license = "Apache 2.0"
    mlmodel.short_description = "NIMA (Neural Image Assessment) Aesthetic Quality Scorer"
    mlmodel.user_defined_metadata["classes"] = "Score 1 to 10 aesthetic distribution"
    
    # Attempt float16 quantization
    try:
        from coremltools.optimize.coreml import (
            OpLinearQuantizerConfig,
            OptimizationConfig,
            linear_quantize_weights,
        )
        print("Applying float16 quantization...")
        config = OptimizationConfig(global_config=OpLinearQuantizerConfig(mode="linear_symmetric", dtype="float16"))
        mlmodel = linear_quantize_weights(mlmodel, config=config)
        print("Float16 quantization successful!")
    except Exception as e:
        print(f"Notice: Float16 quantization skipped ({e}), proceeding with standard weights.")
        
    mlmodel.save(OUTPUT_MLPACKAGE)
    print(f"Saved CoreML model package to {OUTPUT_MLPACKAGE}")
    
    # Also save .mlmodel for compatibility if needed
    try:
        mlmodel.save(OUTPUT_MLMODEL)
    except Exception:
        pass
    
    return mlmodel

def validate_model(mlmodel):
    from PIL import Image
    print("\n--- Validating NIMA Model Prediction ---")
    dummy_img = Image.new("RGB", (224, 224), color=(128, 128, 128))
    pred = mlmodel.predict({"image": dummy_img})
    
    # Get output array
    output_key = list(pred.keys())[0]
    probs = pred[output_key].flatten()
    print(f"Output key: {output_key}")
    print(f"Probabilities (1..10): {np.round(probs, 4)}")
    
    # Expected mean score mu = sum(i * P(i))
    classes = np.arange(1, 11)
    mean_score = np.sum(classes * probs)
    print(f"Predicted Mean Aesthetic Score (mu): {mean_score:.2f} / 10.0")
    
    assert 1.0 <= mean_score <= 10.0, f"Invalid mean score {mean_score}"
    assert np.isclose(np.sum(probs), 1.0, atol=1e-2), f"Probabilities do not sum to 1: {np.sum(probs)}"
    print("Validation PASSED successfully!\n")

if __name__ == "__main__":
    ensure_weights()
    model = build_model()
    mlmodel = convert_to_coreml(model)
    validate_model(mlmodel)
