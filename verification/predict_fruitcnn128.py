"""Use a trained RGB128 checkpoint on a photo or a PC camera."""
import argparse
import json
from pathlib import Path

import cv2
from PIL import Image
import torch

from fruitcnn128 import image_tensor, load_model, normalize


@torch.inference_mode()
def predict(model,saved,image):
    device = next(model.parameters()).device
    logits = model(normalize(image_tensor(image)[None].to(device))).double()
    probabilities = (logits/saved['temperature']).softmax(1)[0].cpu()
    winner = saved['classes'][int(probabilities.argmax())]
    return dict(label=winner if float(probabilities.max())>=saved['threshold'] else 'UNKNOWN',
                winner=winner,confidence=float(probabilities.max()),
                probabilities=dict(zip(saved['classes'],probabilities.tolist())))


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--checkpoint',type=Path,required=True)
    source = p.add_mutually_exclusive_group(required=True)
    source.add_argument('--image',type=Path)
    source.add_argument('--camera',type=int)
    p.add_argument('--device',choices=['cpu','cuda','auto'],default='auto')
    args = p.parse_args()
    torch.set_num_threads(4)
    device = ('cuda' if torch.cuda.is_available() else 'cpu') if args.device=='auto' else args.device
    model,saved = load_model(args.checkpoint,device)
    if args.image:
        with Image.open(args.image) as im:
            print(json.dumps(predict(model,saved,im),ensure_ascii=False,indent=2))
        return
    camera = cv2.VideoCapture(args.camera,cv2.CAP_DSHOW)
    if not camera.isOpened():
        raise RuntimeError('Cannot open camera '+str(args.camera))
    try:
        while True:
            ok,frame = camera.read()
            if not ok:
                raise RuntimeError('Camera frame read failed')
            height,width = frame.shape[:2]
            side = min(height,width)
            left,top = (width-side)//2,(height-side)//2
            roi = frame[top:top+side,left:left+side]
            result = predict(model,saved,Image.fromarray(cv2.cvtColor(roi,cv2.COLOR_BGR2RGB)))
            cv2.rectangle(frame,(left,top),(left+side,top+side),(0,255,0),2)
            cv2.putText(frame,f"{result['label']} {result['confidence']:.1%}",(15,35),
                        cv2.FONT_HERSHEY_SIMPLEX,.8,(0,255,0),2)
            cv2.imshow('Fruit CNN 128 - Q to quit',frame)
            if cv2.waitKey(1)&255 in (27,ord('q')):
                break
    finally:
        camera.release()
        cv2.destroyAllWindows()


if __name__=='__main__':
    main()
