"""Compile pinned SkMatrix predicate bodies; shims supply storage/type flags only."""
from pathlib import Path
import base64
import hashlib
import json
import math
import random
import struct
import subprocess
import tempfile
import urllib.request

sha = '83eece5b45e4090b053dbc7829d6c3df86fb4b9624379972d7dd0d5c8c4965f8'
cache = Path('/tmp/ztransfer-shadow-android15/SkMatrix.cpp')
url = 'https://android.googlesource.com/platform/external/skia/+/android-15.0.0_r1/src/core/SkMatrix.cpp?format=TEXT'
data = cache.read_bytes() if cache.exists() else base64.b64decode(urllib.request.urlopen(url, timeout=30).read())
assert hashlib.sha256(data).hexdigest() == sha
source = data.decode()
start = source.index('static inline bool is_degenerate_2x2')
end = source.index('///////////////////////////////////////////////////////////////////////////////', source.index('bool SkMatrix::preservesRightAngles', start))
body = source[start:end]
shim = r'''
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <cassert>
using SkScalar = float;
constexpr float SK_ScalarNearlyZero = 1.0f/4096;
float SkScalarAbs(float x) { return std::abs(x); }
float SkScalarSquare(float x) { return x*x; }
bool SkScalarNearlyZero(float x,float t=SK_ScalarNearlyZero) { return std::abs(x)<=t; }
bool SkScalarNearlyEqual(float a,float b,float t=SK_ScalarNearlyZero) { return std::abs(a-b)<=t; }
#define SkASSERT assert
struct SkVector { float x,y; void set(float a,float b){x=a;y=b;} float dot(const SkVector& b) const{return x*b.x+y*b.y;} };
struct SkMatrix {
 enum { kMScaleX=0,kMSkewX=1,kMTransX=2,kMSkewY=3,kMScaleY=4,kMTransY=5 };
 enum { kTranslate_Mask=1,kScale_Mask=2,kAffine_Mask=4,kPerspective_Mask=8 };
 using TypeMask=int;
 float fMat[9];
 TypeMask getType() const {
  return ((fMat[2]!=0||fMat[5]!=0)?kTranslate_Mask:0)
   | ((fMat[0]!=1||fMat[4]!=1)?kScale_Mask:0)
   | ((fMat[1]!=0||fMat[3]!=0)?kAffine_Mask:0)
   | ((fMat[6]!=0||fMat[7]!=0||fMat[8]!=1)?kPerspective_Mask:0);
 }
 bool isSimilarity(float tol=SK_ScalarNearlyZero) const;
 bool preservesRightAngles(float tol=SK_ScalarNearlyZero) const;
};
'''
runner = r'''
int main() {
 SkMatrix m;
 while(true) {
  for(int i=0;i<9;++i) { uint32_t bits; if(scanf("%x",&bits)!=1) return 0; memcpy(&m.fMat[i],&bits,4); }
  printf("%d %d\n",m.isSimilarity(),m.preservesRightAngles());
 }
}
'''
def f(value):
    return struct.unpack('<f', struct.pack('<f', value))[0]

def matrix(a,b,c,d,p=0):
    return list(map(f,[a,b,17.25,c,d,-9.5,p,0,1]))

rng=random.Random(179)
cases=[]
tol=1/4096
for scale in [0, tol/2, tol, tol*2, 0.5, 1, 2, 1000]:
    for delta in [-2*tol,-tol,-tol/2,0,tol/2,tol,2*tol]:
        for reflection in [-1,1]:
            cases.append(matrix(scale,0,0,reflection*(scale+delta)))
            cases.append(matrix(0,-scale,reflection*(scale+delta),0))
for _ in range(2000):
    angle=rng.uniform(-math.pi, math.pi)
    sx=rng.choice([0.001,0.5,1,2,100])
    sy=rng.choice([sx,sx,sx+tol,sx+2*tol,sx/2,-sx])
    a,b,c,d=f(sx*math.cos(angle)),f(-sy*math.sin(angle)),f(sx*math.sin(angle)),f(sy*math.cos(angle))
    cases.append(matrix(a,b,c,d))
for _ in range(256):
    cases.append(matrix(*(rng.uniform(-2,2) for _ in range(4)),p=rng.choice([0,0.001])))
with tempfile.TemporaryDirectory(prefix='zt-matrix-reference-') as directory:
    root=Path(directory)
    (root/'reference.cpp').write_text(shim+body+runner)
    subprocess.run(['clang++','-std=c++17','-O0','-ffp-contract=off',str(root/'reference.cpp'),'-o',str(root/'reference')],check=True)
    input_data='\n'.join(' '.join(format(struct.unpack('<I',struct.pack('<f',v))[0],'x') for v in m) for m in cases)+'\n'
    results=subprocess.check_output([str(root/'reference')],input=input_data.encode()).decode().splitlines()
assert len(results)==len(cases)
output=Path(__file__).resolve().parents[1]/'ZTransferTests/Fixtures/android15-shadow-matrix-predicates.json'
output.write_text(json.dumps({'source_sha256':sha,'cases':[{'matrix':m,'similarity':bool(int(r.split()[0])),
    'rightAngles':bool(int(r.split()[1]))} for m,r in zip(cases,results)]},indent=2)+'\n')
print(f'{len(cases)} original SkMatrix predicate cases: {output}')
