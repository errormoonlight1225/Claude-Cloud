import numpy as np, subprocess, sys
W,H,FPS,SEC=1280,720,30,12
N=60000
rng=np.random.default_rng(1)
arm=rng.integers(0,3,N)
r=rng.exponential(0.28,N).clip(0,1.2)
theta=arm*2*np.pi/3 + r*5.5 + rng.normal(0,0.35,N)*(0.3+r)
z=rng.normal(0,0.03,N)
col=np.stack([0.6+0.4*(1-r),0.5+0.3*np.cos(r*4),1.0-0.5*r],1).clip(0,1)
hot=rng.random(N)<0.03; col[hot]=[1,0.85,0.6]
bright=(0.25+0.75*rng.random(N))*np.exp(-r*1.2)
omega=0.6/(0.15+r)  # differential rotation
stars_x=rng.random(800)*W; stars_y=rng.random(800)*H; stars_b=rng.random(800)
out=sys.argv[1]
p=subprocess.Popen(['ffmpeg','-y','-loglevel','error','-f','rawvideo','-pix_fmt','rgb24','-s',f'{W}x{H}','-r',str(FPS),'-i','-',
 '-c:v','libx264','-pix_fmt','yuv420p','-crf','18',out],stdin=subprocess.PIPE)
def blur(img,k):
    for _ in range(3):
        img=(np.roll(img,k,0)+np.roll(img,-k,0)+img)/3
        img=(np.roll(img,k,1)+np.roll(img,-k,1)+img)/3
    return img
for f in range(FPS*SEC):
    t=f/FPS
    th=theta+omega*t*0.25
    tilt=0.45+0.25*np.sin(t*0.4)
    x=r*np.cos(th); y=r*np.sin(th)
    sx=(x*np.cos(t*0.1)-y*np.sin(t*0.1)); sy=(x*np.sin(t*0.1)+y*np.cos(t*0.1))*tilt+z
    scale=330*(1+0.15*t/SEC)
    px=(W/2+sx*scale).astype(int); py=(H/2+sy*scale).astype(int)
    m=(px>=0)&(px<W)&(py>=0)&(py<H)
    img=np.zeros((H,W,3),np.float32)
    tw=0.7+0.3*np.sin(t*3+np.arange(N)[m]*0.1)
    for c in range(3):
        np.add.at(img[:,:,c],(py[m],px[m]),col[m,c]*bright[m]*tw*0.45)
    core=np.exp(-(((np.arange(W)-W/2)**2)[None,:]+((np.arange(H)-H/2)**2/tilt**2)[:,None])/(2*40**2))
    img+=core[:,:,None]*np.array([1.0,0.85,0.6])*0.6
    glow=blur(img,1)*1.2+blur(img,4)*1.5+blur(img,12)*1.5
    img=img+glow
    sb=(0.5+0.5*np.sin(t*2+stars_b*20))*stars_b*0.6
    img[stars_y.astype(int),stars_x.astype(int)]+=sb[:,None]
    img=1-np.exp(-img*1.2)  # tonemap
    fade=min(1,t/1.0,(SEC-t)/1.0)
    p.stdin.write((img*fade*255).clip(0,255).astype(np.uint8).tobytes())
p.stdin.close(); p.wait()
