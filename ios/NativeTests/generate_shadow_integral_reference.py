"""Compile pinned Skia integral LUT bodies; adapters only provide bitmap storage."""
from pathlib import Path
import base64
import hashlib
import json
import subprocess
import tempfile
import urllib.request

url = 'https://android.googlesource.com/platform/external/skia/+/android-15.0.0_r1/src/gpu/BlurUtils.cpp?format=TEXT'
data = base64.b64decode(urllib.request.urlopen(url, timeout=30).read())
assert hashlib.sha256(data).hexdigest() == '08786ab58c87383689fd52b216512d1377c155d1a64903048577b459c05acdca'
source = data.decode()
body = source[source.index('SkBitmap CreateIntegralTable'):source.index('//  Circle Blur')]
shim = r'''
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <vector>
#define SK_ScalarRoot2Over2 0.707106781f
#define SK_MaxS32 INT32_MAX
struct SkImageInfo { int width; static SkImageInfo MakeA8(int w,int) { return {w}; } };
struct SkBitmap {
 std::vector<uint8_t> pixels;
 bool tryAllocPixels(SkImageInfo i) { pixels.resize(i.width); return true; }
 uint8_t* getAddr8(int x,int) { return pixels.data()+x; }
 void setImmutable() {}
};
bool SkIsFinite(float f) { return std::isfinite(f); }
int SkNextPow2(int n) { int result=1; while(result<n)result*=2; return result; }
int sk_float_round2int(float f) { return (int)std::floor(f+0.5f); }
uint8_t SkToU8(int n) { return static_cast<uint8_t>(n); }
'''
runner = r'''
int main(int argc,char** argv) {
 float sigma=std::strtof(argv[1],nullptr);
 auto table=CreateIntegralTable(ComputeIntegralTableWidth(6*sigma));
 fwrite(table.pixels.data(),1,table.pixels.size(),stdout);
}
'''
cases=[]
with tempfile.TemporaryDirectory(prefix='zt-integral-reference-') as directory:
    root=Path(directory)
    (root/'reference.cpp').write_text(shim+body+runner)
    subprocess.run(['clang++','-std=c++17','-O0','-ffp-contract=off',str(root/'reference.cpp'),'-o',str(root/'reference')],check=True)
    for sigma in [0.030001, 0.1, 1, 2, 2.6666665, 2.666667, 4, 8, 16, 32, 64, 128]:
        pixels=subprocess.check_output([str(root/'reference'),str(sigma)])
        cases.append(dict(sigma=sigma,pixels=list(pixels)))
output=Path(__file__).resolve().parents[1]/'ZTransferTests/Fixtures/android15-shadow-integral.json'
output.write_text(json.dumps({'cases':cases},indent=2)+'\n')
print(f'{len(cases)} integral LUTs, {sum(len(c["pixels"]) for c in cases)} exact bytes: {output}')

# Circle source bodies are compiled unchanged. The plan is extracted from
# create_profile_effect, excluding GPU/cache ownership and bitmap upload.
plan_data=base64.b64decode(urllib.request.urlopen(
    'https://android.googlesource.com/platform/external/skia/+/android-15.0.0_r1/src/gpu/ganesh/GrBlurUtils.cpp?format=TEXT',timeout=30).read())
assert hashlib.sha256(plan_data).hexdigest() == '91d4ca8c0e88f95752c436813d780dcd9123ec4a002dce5e3f54f3e530079579'
plan_source=plan_data.decode()
start=plan_source.index('    SkScalar sigmaToCircleRRatio = sigma / circleR;')
plan=plan_source[start:plan_source.index('    static constexpr int kProfileTextureWidth',start)]
a=source.index('static float make_unnormalized_half_kernel')
b=source.index('//  RRect Blur',a)
circle_body=source[a:b]
circle_shim=shim+r'''
#include <cassert>
#define SkASSERT assert
using SkScalar=float; using SkFixed=int32_t;
int SkScalarFloorToInt(float x) { return (int)std::floor(x); }
int SkScalarCeilToInt(float x) { return (int)std::ceil(x); }
SkFixed SkScalarToFixed(float x) { return (SkFixed)(x*65536.f); }
float SkFixedToScalar(SkFixed x) { return x*(1.f/65536.f); }
unsigned SkUnitScalarClampToByte(float x) { return (unsigned)(std::clamp(x,0.f,1.f)*255+0.5); }
namespace skia_private { template<class T> struct AutoTArray {
 std::vector<T> data; explicit AutoTArray(int n): data(n) {} T* get(){return data.data();}
 T& operator[](int i){return data[i];}
}; }
'''
circle_runner='''
int main(int argc,char** argv) {
 float circleR=std::strtof(argv[1],nullptr), sigma=std::strtof(argv[2],nullptr);
 float solid,texture;float* solidRadius=&solid;float* textureRadius=&texture;
'''+plan+'''
 const float scale=512.f/texture;
 auto table=useHalfPlaneApprox?CreateHalfPlaneProfile(512):CreateCircleProfile(sigma*scale,circleR*scale,512);
 printf("%d %.9g %.9g\\n",sigmaToCircleRRatioFixed,solid,texture);
 fwrite(table.pixels.data(),1,table.pixels.size(),stdout);
}
'''
circle_cases=[]
with tempfile.TemporaryDirectory(prefix='zt-circle-reference-') as directory:
    root=Path(directory)
    (root/'reference.cpp').write_text(circle_shim+circle_body+circle_runner)
    subprocess.run(['clang++','-std=c++17','-O0','-ffp-contract=off',str(root/'reference.cpp'),'-o',str(root/'reference')],check=True)
    for radius,sigma in [(10,0.5),(10,1),(10,1.000001),(10,1.015624),(10,1.015626),(1,1),(1,8),(1,128),(32,6),(256,16),(0.000244140625,0.04),(100000,128)]:
        raw=subprocess.check_output([str(root/'reference'),str(radius),str(sigma)])
        header,pixels=raw.split(b'\n',1);key,solid,texture=header.split()
        assert len(pixels)==512
        circle_cases.append(dict(radius=radius,sigma=sigma,key=int(key),solidRadius=float(solid),textureRadius=float(texture),pixels=list(pixels)))
circle_output=output.with_name('android15-shadow-circle-profile.json')
circle_output.write_text(json.dumps({'cases':circle_cases},indent=2)+'\n')
print(f'{len(circle_cases)} circle profiles: {circle_output}')

# Original nine-patch parameter function, with simple circular rrect adapters.
start=plan_source.index('bool ComputeBlurredRRectParams(')
end=plan_source.index('\nvoid DrawShapeWithMaskFilter',start)
rrect_body=plan_source[start:end]
rrect_shim=circle_shim+r'''
static constexpr int kBlurRRectMaxDivisions=4;
float SkScalarCeilToScalar(float x) { return std::ceil(x); }
float SkIntToScalar(int x) { return (float)x; }
struct SkVector { float fX,fY; };
struct SkISize { int fWidth,fHeight; };
struct SkRect {
 float fLeft,fTop,fRight,fBottom;
 SkRect makeOutset(float x,float y) const {return {fLeft-x,fTop-y,fRight+x,fBottom+y};}
 static SkRect MakeXYWH(float x,float y,float w,float h) {return {x,y,x+w,y+h};}
};
struct SkRRect {
 enum Corner { kUpperLeft_Corner,kUpperRight_Corner,kLowerRight_Corner,kLowerLeft_Corner };
 SkRect rect; SkVector corners[4];
 const SkRect& getBounds() const {return rect;}
 const SkVector& radii(Corner c) const {return corners[c];}
 void setRectRadii(SkRect r,const SkVector* v){rect=r;for(int i=0;i<4;i++)corners[i]=v[i];}
};
'''
rrect_runner=r'''
int main(int argc,char** argv) {
 float x=std::strtof(argv[1],nullptr),y=std::strtof(argv[2],nullptr),w=std::strtof(argv[3],nullptr),h=std::strtof(argv[4],nullptr);
 float radius=std::strtof(argv[5],nullptr),sigma=std::strtof(argv[6],nullptr);
 SkRRect r{{x,y,x+w,y+h},{{radius,radius},{radius,radius},{radius,radius},{radius,radius}}},out;
 SkISize size;float a[4],b[4],c[4],d[4];
 bool accepted=ComputeBlurredRRectParams(r,r,sigma,sigma,&out,&size,a,b,c,d);
 if(!accepted){puts("0");return 0;}
 printf("1 %d %d %.9g %.9g %.9g %.9g %.9g\n",size.fWidth,size.fHeight,out.rect.fLeft,out.rect.fTop,out.rect.fRight,out.rect.fBottom,out.corners[0].fX);
}
'''
rrect_cases=[]
with tempfile.TemporaryDirectory(prefix='zt-rrect-plan-reference-') as directory:
    root=Path(directory)
    (root/'reference.cpp').write_text(rrect_shim+rrect_body+rrect_runner)
    subprocess.run(['clang++','-std=c++17','-O0','-ffp-contract=off',str(root/'reference.cpp'),'-o',str(root/'reference')],check=True)
    for sigma in [0.04, 1/6, 0.166667, 1, 1.1666666, 1.166667, 4, 32, 128]:
        for radius in [0.5, 5, 5.25, 22]:
            for x,y,w,h in [(0,0,2000,1700),(0.25,-7.25,40,30),(-17,31,64,80)]:
                if 2*radius>min(w,h):continue
                values=subprocess.check_output([str(root/'reference'),*map(str,[x,y,w,h,radius,sigma])],text=True).split()
                case=dict(bounds=[x,y,x+w,y+h],radius=radius,sigma=sigma,accepted=values[0]=='1')
                if case['accepted']:case.update(size=list(map(int,values[1:3])),mask=list(map(float,values[3:7])),corner=float(values[7]))
                rrect_cases.append(case)
rrect_output=output.with_name('android15-shadow-rrect-plan.json')
rrect_output.write_text(json.dumps({'cases':rrect_cases},indent=2)+'\n')
print(f'{len(rrect_cases)} nine-patch plans: {rrect_output}')
