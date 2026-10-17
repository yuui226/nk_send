"""Pinned Skia PlanGauss byte reference; original scan is compiled, not reimplemented."""
from pathlib import Path
import base64
import hashlib
import json
import subprocess
import tempfile
import urllib.request

url = 'https://android.googlesource.com/platform/external/skia/+/android-15.0.0_r1/src/core/SkMaskBlurFilter.cpp?format=TEXT'
data = base64.b64decode(urllib.request.urlopen(url, timeout=30).read())
assert hashlib.sha256(data).hexdigest() == '92e765db1c237502f95f2f5457a2861d37153b72bf7646f842dd0ca2efd1aa53'
source = data.decode()
body = source[source.index('static const double kPi'):source.index('} // namespace')]
shim = r'''
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <cstdio>
#include <cstdlib>
#include <vector>
template<class T, class U> T SkTo(U value) { return static_cast<T>(value); }
'''
runner = r'''
int main(int argc,char** argv) {
 double sigma=std::strtod(argv[1],nullptr);int w=std::atoi(argv[2]),h=std::atoi(argv[3]),pattern=std::atoi(argv[4]);
 PlanGauss plan(sigma);int border=plan.border(),dw=w+2*border,dh=h+2*border;
 std::vector<uint8_t> src(w*h),tmp(dw*h),dst(dw*dh);
 for(int y=0;y<h;y++)for(int x=0;x<w;x++)src[y*w+x]=pattern==0?255:pattern==1?((x==w/2&&y==h/2)?255:0):((x*71+y*37+83)%256);
 std::vector<uint32_t> buffer(plan.bufferSize());
 auto horizontal=plan.makeBlurScan(w,buffer.data());
 for(int y=0;y<h;y++)horizontal.blur(src.data()+y*w,src.data()+(y+1)*w,tmp.data()+y,h,tmp.data()+y+dw*h);
 auto vertical=plan.makeBlurScan(h,buffer.data());
 for(int x=0;x<dw;x++)vertical.blur(tmp.data()+x*h,tmp.data()+(x+1)*h,dst.data()+x,dw,dst.data()+x+dw*dh);
 printf("%d %d %d\n",dw,dh,border);fwrite(dst.data(),1,dst.size(),stdout);
}
'''
cases = []
with tempfile.TemporaryDirectory(prefix='zt-box-blur-reference-') as temporary:
    root = Path(temporary)
    (root/'reference.cpp').write_text(shim+body+runner)
    subprocess.run(['clang++','-std=c++17','-O0','-ffp-contract=off',str(root/'reference.cpp'),'-o',str(root/'reference')],check=True)
    for sigma in [2, 2.1, 3, 4, 8, 32, 128, 135]:
        for width,height in [(1,1),(2,7),(19,13)]:
            for pattern in [0,1,2]:
                raw = subprocess.check_output([str(root/'reference'),str(sigma),str(width),str(height),str(pattern)])
                header,pixels = raw.split(b'\n',1)
                out_width,out_height,border = map(int,header.split())
                assert len(pixels) == out_width*out_height
                cases.append(dict(sigma=sigma,width=width,height=height,pattern=pattern,outWidth=out_width,outHeight=out_height,border=border,sha256=hashlib.sha256(pixels).hexdigest()))
output=Path(__file__).resolve().parents[1]/'ZTransferTests/Fixtures/android15-shadow-box-blur.json'
output.write_text(json.dumps({'cases':cases},indent=2)+'\n')
print(f'{len(cases)} exact A8 hashes: {output}')

# Preserve the original SIMD functions; replace only eight-lane vector storage
# and operators with scalar lanes, retaining uint16 wrapping and mulhi semantics.
small_header = base64.b64decode(urllib.request.urlopen('https://android.googlesource.com/platform/external/skia/+/android-15.0.0_r1/src/core/SkGaussFilter.h?format=TEXT',timeout=30).read())
small_source = base64.b64decode(urllib.request.urlopen('https://android.googlesource.com/platform/external/skia/+/android-15.0.0_r1/src/core/SkGaussFilter.cpp?format=TEXT',timeout=30).read())
assert hashlib.sha256(small_header).hexdigest() == '22de968d64263a591fc132d5dae1d6c4d3c664948116dc23f91aa19577117a8e'
assert hashlib.sha256(small_source).hexdigest() == '455ebbdefb5bbe55c8f4f3d6e8e6d252055f66bdb41370c8ad40046a3ebbfbfa'
vector_shim = r'''
#include <cassert>
#include <initializer_list>
#define SkASSERT(x) assert(x)
#define SkASSERTF(x,...) assert(x)
namespace skvx {
template<int N,class T> struct Vec {
 T lanes[N]{};
 Vec()=default;Vec(T value){for(auto& x:lanes)x=value;}
 Vec(std::initializer_list<T> values){int i=0;for(T v:values)lanes[i++]=v;}
 T operator[](int i)const{return lanes[i];}
 static Vec Load(const T* p){Vec r;for(int i=0;i<N;i++)r.lanes[i]=p[i];return r;}
 void store(T* p)const{for(int i=0;i<N;i++)p[i]=lanes[i];}
 Vec& operator+=(Vec b){for(int i=0;i<N;i++)lanes[i]+=b.lanes[i];return *this;}
 friend Vec operator+(Vec a,Vec b){return a+=b;}
 friend Vec operator+(Vec a,T b){return a+=Vec(b);}
 friend Vec operator<<(Vec a,int n){for(auto& x:a.lanes)x<<=n;return a;}
 friend Vec operator>>(Vec a,int n){for(auto& x:a.lanes)x>>=n;return a;}
};
using byte8=Vec<8,uint8_t>;
template<class T,int N,class U> Vec<N,T> cast(Vec<N,U> a){Vec<N,T> r;for(int i=0;i<N;i++)r.lanes[i]=T(a[i]);return r;}
Vec<8,uint16_t> mulhi(Vec<8,uint16_t> a,Vec<8,uint16_t> b){Vec<8,uint16_t> r;for(int i=0;i<8;i++)r.lanes[i]=(uint32_t(a[i])*b[i])>>16;return r;}
}
using ToA8=void(uint8_t*,const uint8_t*,int);
'''
small_body = source[source.index('using fp88 ='):source.index('static SkIPoint small_blur')]
gauss_body = small_source.decode()[small_source.decode().index('static constexpr double kGoodEnough'):]
small_runner = r'''
int main(int argc,char** argv){
 double sigma=std::strtod(argv[1],nullptr);int w=std::atoi(argv[2]),h=std::atoi(argv[3]),pattern=std::atoi(argv[4]);
 SkGaussFilter filter(sigma);int radius=filter.radius(),dw=w+2*radius,dh=h+2*radius;
 uint16_t factors[6]={};int i=0;for(double value:filter)factors[i++]=uint16_t(round(value*65536));
 std::vector<uint8_t> src(w*h),dst(dw*dh);
 for(int y=0;y<h;y++)for(int x=0;x<w;x++)src[y*w+x]=pattern==0?255:pattern==1?((x==w/2&&y==h/2)?255:0):((x*71+y*37+83)%256);
 direct_blur_y(nullptr,8,radius,factors,src.data(),w,w,h,dst.data()+radius,dw);
 direct_blur_x(radius,factors,dst.data()+radius,dw,w,dst.data(),dw,dw,dh);
 printf("%d %d %d",dw,dh,radius);for(int j=0;j<=radius;j++)printf(" %u",factors[j]);printf("\n");
 fwrite(dst.data(),1,dst.size(),stdout);
}
'''
small_cases=[]
with tempfile.TemporaryDirectory(prefix='zt-small-blur-reference-') as temporary:
    root=Path(temporary)
    (root/'reference.cpp').write_text(shim+vector_shim+small_header.decode()+gauss_body+small_body+small_runner)
    subprocess.run(['clang++','-std=c++17','-O0','-ffp-contract=off',str(root/'reference.cpp'),'-o',str(root/'reference')],check=True)
    for sigma in [0.334,0.4,0.5,0.75,1,1.25,1.5,1.75,1.999999]:
        for width,height in [(1,1),(2,7),(7,2),(8,8),(9,3),(19,13)]:
            for pattern in [0,1,2]:
                raw=subprocess.check_output([str(root/'reference'),str(sigma),str(width),str(height),str(pattern)])
                header,pixels=raw.split(b'\n',1)
                values=list(map(int,header.split()));out_width,out_height,border=values[:3]
                assert len(pixels)==out_width*out_height
                small_cases.append(dict(sigma=sigma,width=width,height=height,pattern=pattern,outWidth=out_width,outHeight=out_height,border=border,factors=values[3:],sha256=hashlib.sha256(pixels).hexdigest()))
small_output=output.with_name('android15-shadow-small-blur.json')
small_output.write_text(json.dumps({'cases':small_cases},indent=2)+'\n')
print(f'{len(small_cases)} exact small A8 hashes: {small_output}')
