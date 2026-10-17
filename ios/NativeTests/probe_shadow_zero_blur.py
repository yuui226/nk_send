"""Probe pinned Skia fast-shadow vertex writers at zero blur.

This executes original constructor calculations, vertex writers and point
normalization, with storage/type shims. It does not run a GPU or establish
Android fragment coverage. Nonfinite values are JSON strings, never JSON NaN.
No app build, fixture replacement, or production code is involved.
"""
from pathlib import Path
import argparse
import base64
import hashlib
import json
import math
import subprocess
import tempfile
import urllib.request

SOURCES = {
    'GrShadowRRectOp.cpp': ('src/gpu/ganesh/ops/ShadowRRectOp.cpp',
        '197766680a70cf54dfb2ad05beeb8ffb0c28a9b2f1b91838be46f400b9b97215'),
    'SkPoint.cpp': ('src/core/SkPoint.cpp',
        '5534efdc0a13f3e8c69d510ca2d308339673715ef5cd2bbb75ed165aaff6df2b'),
}


def pinned(name, cache):
    path, digest = SOURCES[name]
    local = cache / name
    if local.exists():
        data = local.read_bytes()
    else:
        url = ('https://android.googlesource.com/platform/external/skia/+/'
               f'android-15.0.0_r1/{path}?format=TEXT')
        data = base64.b64decode(urllib.request.urlopen(url, timeout=30).read())
    if hashlib.sha256(data).hexdigest() != digest:
        raise ValueError(f'Pinned source mismatch: {name}')
    return data.decode()


def between(source, start, end):
    begin = source.index(start)
    return source[begin:source.index(end, begin)]


SHIM = r'''
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cassert>
using SkScalar = float;
using GrColor = unsigned;
#define SkASSERT assert
constexpr float SK_ScalarSqrt2 = 1.4142135623730950488f;
double sk_ieee_double_divide(double x,double y) { return x/y; }
float sk_double_to_float(double x) { return float(x); }
bool SkIsFinite(float x,float y) { return std::isfinite(x)&&std::isfinite(y); }
struct SkPoint {
 float fX,fY;
 static SkPoint Make(float x,float y) { return {x,y}; }
 SkPoint operator+(SkPoint p) const { return {fX+p.fX,fY+p.fY}; }
 void set(float x,float y) {fX=x;fY=y;}
 bool normalize();
 bool setLength(float x,float y,float length);
};
using SkVector = SkPoint;
struct SkRect {
 float fLeft,fTop,fRight,fBottom;
 float width() const { return fRight-fLeft; }
 float height() const { return fBottom-fTop; }
 float centerX() const { return float(0.5*(double(fLeft)+double(fRight))); }
 float centerY() const { return float(0.5*(double(fTop)+double(fBottom))); }
};
enum RRectType {kFill_RRectType,kStroke_RRectType,kOverstroke_RRectType};
struct Geometry {
 GrColor fColor;float fOuterRadius,fUmbraInset,fInnerRadius,fBlurRadius;
 SkRect fDevBounds;RRectType fType;
};
struct CircleVertex {SkPoint fPos;GrColor fColor;SkPoint fOffset;float fDistanceCorrection;};
'''
MAIN = r'''
int main() {
 for(bool isCircle : {false,true}) {
  for(float radius : {0.f,4.f,20.f}) {
   if(isCircle && radius==0) continue;
   for(float blurRadius : {0.f,2.f}) {
    for(float insetWidth : {1.f,80.f}) {
     float devRadius=radius;
     SkRect devRect=isCircle ? SkRect{-radius,-radius,radius,radius} : SkRect{0,0,80,40};
     // ORIGINAL_CONSTRUCTOR
     Geometry geometry{0,outerRadius,umbraInset,innerRadius,blurRadius,devRect,type};
     CircleVertex vertices[28];CircleVertex* next=vertices;
     if(isCircle) Reference{}.fillInCircleVerts(geometry,type==kStroke_RRectType,&next);
     else Reference{}.fillInRRectVerts(geometry,&next);
     printf("%d %.9g %.9g %.9g %d %ld\n",isCircle,radius,blurRadius,insetWidth,int(type),next-vertices);
     for(auto* v=vertices;v<next;++v)
      printf("%.9g %.9g %.9g %.9g %.9g\n",v->fPos.fX,v->fPos.fY,v->fOffset.fX,v->fOffset.fY,v->fDistanceCorrection);
    }
   }
  }
 }
}
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--cache', type=Path, default=Path('/tmp/ztransfer-shadow-android15'))
    parser.add_argument('--output', type=Path, default=Path('/tmp/ztransfer-shadow-zero-blur.json'))
    args = parser.parse_args()
    op = pinned('GrShadowRRectOp.cpp', args.cache)
    point = pinned('SkPoint.cpp', args.cache)
    constructor = between(op, '        SkScalar innerRadius = 0.0f;', '        this->setBounds')
    writers = between(op, '    void fillInCircleVerts(', '    GrProgramInfo* programInfo()')
    normalize = between(point, 'bool SkPoint::normalize()', 'bool SkPoint::setNormalize')
    normalize += between(point, 'template <bool use_rsqrt>', 'float SkPoint::Normalize')
    normalize += between(point, 'bool SkPoint::setLength(float x', 'bool SkPointPriv::SetLengthFast')
    source = SHIM + normalize + '\nstruct Reference {\n' + writers + '\n};\n'
    source += MAIN.replace('// ORIGINAL_CONSTRUCTOR', constructor)
    with tempfile.TemporaryDirectory(prefix='zt-shadow-zero-blur-') as temp:
        root = Path(temp)
        cpp, exe = root / 'reference.cpp', root / 'reference'
        cpp.write_text(source)
        subprocess.run(['clang++', '-std=c++17', '-O0', '-ffp-contract=off',
                        str(cpp), '-o', str(exe)], check=True)
        lines = iter(subprocess.check_output([str(exe)], text=True).splitlines())
    cases = []
    for line in lines:
        circle, radius, blur, inset, kind, count = map(float, line.split())
        vertices = [list(map(float, next(lines).split())) for _ in range(int(count))]
        # Finite controls distinguish genuine zero-blur output from a broken shim.
        assert all(math.isfinite(v) for vertex in vertices for v in vertex[:2])
        if blur > 0:
            assert all(math.isfinite(v) for vertex in vertices for v in vertex)
        else:
            assert all(not math.isfinite(vertex[4]) for vertex in vertices)
            assert all(math.isnan(vertex[4]) == (radius == 0) for vertex in vertices)
            bad_offsets = sum(any(not math.isfinite(v) for v in vertex[2:4])
                              for vertex in vertices)
            assert bad_offsets == (4 if radius == 0 else 0)
            if radius > 0:
                assert all(vertex[4] == math.inf for vertex in vertices)
        serialized = [[v if math.isfinite(v) else ('nan' if math.isnan(v) else
                       '+inf' if v > 0 else '-inf') for v in vertex] for vertex in vertices]
        cases.append(dict(circle=bool(circle), radius=radius, blur=blur, inset=inset,
                          kind=int(kind), vertices=serialized))
    assert len(cases) == 20
    args.output.write_text(json.dumps(dict(sources=SOURCES, cases=cases,
        scope='Original CPU vertex writers; no GPU, dispatch, half conversion or pixel verification'),
        indent=2, allow_nan=False) + '\n')
    print(f'PASS: {len(cases)} native cases (10 zero-blur, 10 finite controls): {args.output}')


if __name__ == '__main__':
    main()
