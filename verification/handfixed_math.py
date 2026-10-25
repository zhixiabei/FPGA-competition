"""Bit-exact fixed-ROI geometry and W8A16 execution."""
import numpy as np
import torch
import torch.nn.functional as F
FILL = [124,116,104]

def resize_roi(rgb,box,width,height):
    x,y,r,b=box
    rw,rh=r-x,b-y
    xs=(x<<16)+((rw<<16)//(2*width))-32768+np.arange(width,dtype=np.int64)*((rw<<16)//width)
    ys=(y<<16)+((rh<<16)//(2*height))-32768+np.arange(height,dtype=np.int64)*((rh<<16)//height)
    xs=np.clip(xs,x<<16,(r-1)<<16);ys=np.clip(ys,y<<16,(b-1)<<16)
    x0=xs>>16;y0=ys>>16
    x1=x0+((xs&65535)!=0);y1=y0+((ys&65535)!=0)
    fx=(xs>>8)&255;fy=(ys>>8)&255
    def sample(xx,yy):
        valid=(xx[None,:]>=0)&(xx[None,:]<rgb.shape[1])&(yy[:,None]>=0)&(yy[:,None]<rgb.shape[0])
        value=rgb[np.clip(yy,0,rgb.shape[0]-1)[:,None],np.clip(xx,0,rgb.shape[1]-1)[None,:]].astype(np.int64)
        return np.where(valid[:,:,None],value,np.array(FILL)[None,None,:])
    a,b,c,d=sample(x0,y0),sample(x1,y0),sample(x0,y1),sample(x1,y1)
    top=(a*(256-fx[None,:,None])+b*fx[None,:,None]+128)>>8
    bottom=(c*(256-fx[None,:,None])+d*fx[None,:,None]+128)>>8
    return ((top*(256-fy[:,None,None])+bottom*fy[:,None,None]+128)>>8).astype(np.uint8)


def snapshot(rgb):
    h,w=rgb.shape[:2]
    rh=min(720,(h*1280+w//2)//w);rw=min(1280,(w*720+h//2)//h)
    px,py=(1280-rw)//2,(720-rh)//2
    out=np.full((720,1280,3),FILL,dtype=np.uint8)
    out[py:py+rh,px:px+rw]=resize_roi(rgb,[0,0,w,h],rw,rh)
    return out,(rw/w,rh/h,px,py)


def normalize(a,classifier=False):
    x=torch.from_numpy(a.copy()).permute(2,0,1).unsqueeze(0).float()/255
    if classifier:
        return (x-torch.tensor([.485,.456,.406])[None,:,None,None])/torch.tensor([.229,.224,.225])[None,:,None,None]
    return (x-.5)*2


def integer_run(ops,x,collect=False):
    x=torch.round(x/2.**ops[0]['src_exp']).clamp(-32768,32767).double()
    values=[x]
    for op in ops:
        if op['kind']==1:
            x=F.avg_pool2d(x,3,3).floor()
        else:
            x=x.reshape(x.shape[0],*op['input_shape'])
            w=torch.tensor(op['weights'],dtype=torch.float64).reshape(op['cout'],op['cin'],op['kernel'],op['kernel'])
            b=torch.tensor(op['biases'],dtype=torch.float64)
            x=F.conv2d(x,w,b,stride=op['stride'],padding=op['padding'])
            x=torch.floor(x/torch.pow(2.,torch.tensor(op['shifts'],dtype=torch.float64))[None,:,None,None])
            x=x.clamp(0 if op['relu'] else -32768,32767)
        values.append(x)
    return values if collect else x


def align(n,b=16):return (n+b-1)//b*b


def feature_bytes(x):
    a=x.detach().cpu().numpy().astype('<i2')[0]
    planes=[]
    for plane in a:
        p=plane.tobytes();planes.append(p+bytes(align(len(p))-len(p)))
    return b''.join(planes)


