"""Check the retrained checkpoint contract against the previous fruit model."""
import ast
import hashlib
import json
from pathlib import Path
import sys

import torch
from PIL import Image

ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT / 'source'))
from fruitcnn128 import load_model, image_tensor, normalize, model_budget


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def algorithm_ast(path):
    tree = ast.parse(path.read_text(encoding='utf-8-sig'))
    # The old snapshot's default fifth-class label and default output directory
    # were updated after its run; both are explicitly supplied for this run.
    for node in ast.walk(tree):
        if isinstance(node, ast.Assign) and any(isinstance(t, ast.Name) and t.id == 'CLASSES' for t in node.targets):
            if path.name == 'fruitcnn128.py':
                node.value = ast.Constant(value='explicit_class_list')
        if isinstance(node, ast.Assign) and any(isinstance(t, ast.Name) and t.id == 'out' for t in node.targets):
            if path.name == 'train_fruitcnn128.py' and isinstance(node.value, ast.BoolOp):
                node.value = ast.Constant(value='explicit_output_directory')
    return ast.dump(tree, include_attributes=False)


def main():
    torch.set_num_threads(4)
    training = ROOT / 'training'
    baseline = json.loads((ROOT / 'baseline_checkpoint.json').read_text(encoding='utf-8'))
    old_path = Path(baseline['path'])
    assert sha(old_path) == baseline['sha256'], 'Previous checkpoint changed'
    algorithm_files = ['train_fruitcnn128.py', 'fruitcnn128.py', 'fruitcnn.py', 'fruitcnn_training.py',
                       'handcnn_model.py', 'handcnn_training_utils.py', 'handfixed_math.py']
    for name in algorithm_files:
        assert algorithm_ast(old_path.parent / 'source' / name) == algorithm_ast(ROOT / 'source' / name), name
    old_model, old = load_model(old_path)
    new_model, new = load_model(training / 'model.pt')
    for key in ('architecture', 'preprocess', 'classes', 'threshold', 'budget',
                'shape_supervision', 'texture_supervision', 'selection'):
        assert new[key] == old[key], f'Original model contract mismatch: {key}'
    train_keys = ['device', 'threads', 'amp', 'epochs', 'batch', 'seed', 'lr', 'weight_decay',
                  'shape_weight', 'texture_weight', 'pair_weight', 'outlier_weight',
                  'hardware_probability', 'threshold', 'repeats', 'patience', 'min_epochs']
    for key in train_keys:
        assert new['training'][key] == old['training'][key], f'Training setting mismatch: {key}'
    old_state, new_state = old_model.state_dict(), new_model.state_dict()
    assert set(old_state) == set(new_state)
    assert all(old_state[k].shape == new_state[k].shape for k in old_state)
    assert torch.equal(old_model.features[0].weight[:6], new_model.features[0].weight[:6])
    assert not torch.equal(old_model.fc.weight, new_model.fc.weight), 'Weights were not retrained'
    assert not any(k.startswith(('shape_head.', 'texture_head.')) for k in new_state)
    last = torch.load(training / 'last.pt', map_location='cpu', weights_only=True)
    assert last['complete']
    assert last['model']['shape_head.weight'].shape == (64, 384)
    assert last['model']['texture_head.weight'].shape == (160, 384)
    completion = json.loads((training / 'completion.json').read_text(encoding='utf-8'))
    evaluation = json.loads((training / 'evaluation.json').read_text(encoding='utf-8'))
    assert completion['status'] == 'complete'
    assert sha(training / 'model.pt') == completion['checkpoint_sha256'] == evaluation['checkpoint_sha256']
    manifest = json.loads((training / 'data_manifest.json').read_text(encoding='utf-8'))
    group_splits, file_splits, input_splits = {}, {}, {}
    for sample in manifest['samples']:
        for mapping, key in [(group_splits, 'group'), (file_splits, 'source_sha256'), (input_splits, 'input_sha256')]:
            previous = mapping.setdefault(sample[key], sample['split'])
            assert previous == sample['split'], 'Cross-split leakage: ' + key
        assert sample['dataset'] != 'pictures' or sample['split'] == 'train'
    selected = [next(s for s in manifest['samples'] if s['split'] == 'test' and s['label'] == c)
                for c in new['classes']]
    inputs = []
    for sample in selected:
        with Image.open(sample['path']) as image:
            inputs.append(image_tensor(image))
    with torch.inference_mode():
        logits = new_model(normalize(torch.stack(inputs)))
        probabilities = (logits.double() / new['temperature']).softmax(1)
    assert logits.shape == (5, 5) and torch.isfinite(probabilities).all()
    assert torch.allclose(probabilities.sum(1), torch.ones(5, dtype=torch.float64))
    snapshot = json.loads((ROOT / 'source_snapshot.json').read_text(encoding='utf-8'))
    assert all(sha(ROOT / 'source' / name) == digest for name, digest in snapshot.items())
    report = dict(status='passed', architecture=new['architecture'],
                  original_checkpoint_unchanged=True, same_architecture_and_preprocessing=True,
                  original_training_and_model_source_algorithms_match=True,
                  same_class_order=True, same_parameter_names_and_shapes=True,
                  same_fixed_scharr_and_laplacian_filters=True, same_training_settings=True,
                  training_shape_and_texture_heads_present=True, inference_auxiliary_heads_removed=True,
                  weights_retrained=True, source_snapshot_unchanged=True,
                  no_group_file_or_input_hash_overlap=True, phone_photos_training_only=True,
                  inference_parameters=model_budget(new_model)['inference_parameters'],
                  epochs_completed=last['epoch'], best_epoch=new['best_epoch'],
                  temperature=new['temperature'], checkpoint_sha256=completion['checkpoint_sha256'],
                  cpu_inference_verified=True,
                  sample_predictions=[dict(truth=s['label'], prediction=new['classes'][int(p.argmax())],
                                           confidence=float(p.max())) for s, p in zip(selected, probabilities)])
    (ROOT / 'verification_report.json').write_text(json.dumps(report, indent=2) + '\n', encoding='utf-8')
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    main()
