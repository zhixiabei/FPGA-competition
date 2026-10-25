"""OpenCV camera and Unicode image loading helpers."""
import cv2
import numpy as np

def read_image(path):
    image = cv2.imdecode(np.fromfile(path, dtype=np.uint8), cv2.IMREAD_COLOR)
    if image is None:
        raise ValueError(f'Cannot open photo: {path}')
    return image


def open_camera(index):
    for backend in [cv2.CAP_DSHOW, cv2.CAP_MSMF, cv2.CAP_ANY]:
        print(f'Opening camera {index}, backend {backend}...', flush=True)
        cap = cv2.VideoCapture(index, backend)
        if cap.isOpened():
            ok, frame = cap.read()
            if ok:
                print(f'Camera ready: {frame.shape[1]}x{frame.shape[0]}', flush=True)
                return cap, frame
        cap.release()
    raise RuntimeError(f'Camera {index} unavailable. Use --camera 1 or --gallery.')


