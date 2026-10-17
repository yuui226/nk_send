"""Generate metrics from pinned, unmodified Skia function bodies; no iOS code runs.

Only scalar/type shims replace Skia's includes. Inputs avoid NaN/undefined cases.
Use Android 15 Soong cc/config/global.go's -ffp-contract=off; host Clang's
default fused arithmetic can change degenerate-curve decisions.
The generator never builds an Android APK or modifies dist/.
"""
from pathlib import Path
import base64
import hashlib
import json
import subprocess
import tempfile
import urllib.request

URL = 'https://android.googlesource.com/platform/external/skia/+/android-15.0.0_r1/src/core/SkDrawShadowInfo.h?format=TEXT'
SHA = 'a297b6bbdb464a51a18a1343f0978bee1663e9df1340bc3a3ffa666c71badee3'
data = base64.b64decode(urllib.request.urlopen(URL, timeout=30).read())
assert hashlib.sha256(data).hexdigest() == SHA
source = data.decode()
body = source[source.index('namespace SkDrawShadowMetrics {'):source.index('inline void GetDirectionalParams')]
shim = r'''
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cassert>
using SkScalar = float;
struct SkVector { float fX, fY; static SkVector Make(float x, float y) { return {x,y}; } };
#define SkASSERT assert
float sk_ieee_float_divide(float x, float y) { return x/y; }
template<class T> T SkTPin(T x,T lo,T hi) { return std::clamp(x,lo,hi); }
'''
OP_URL = 'https://android.googlesource.com/platform/external/skia/+/android-15.0.0_r1/src/gpu/ganesh/ops/ShadowRRectOp.cpp?format=TEXT'
OP_SHA = '197766680a70cf54dfb2ad05beeb8ffb0c28a9b2f1b91838be46f400b9b97215'
op_data = base64.b64decode(urllib.request.urlopen(OP_URL, timeout=30).read())
assert hashlib.sha256(op_data).hexdigest() == OP_SHA
op = op_data.decode()
loop_start = op.index('    for (int i = 0; i < 128; ++i)')
loop = op[loop_start:op.index('    bitmap.setImmutable();', loop_start)]
shim += r"""
constexpr float SK_Scalar1 = 1.f;
float SkIntToScalar(int x) { return float(x); }
float SkScalarExp(float x) { return std::exp(x); }
int SkScalarRoundToInt(float x) { return int(std::floor(x + 0.5f)); }
"""
main = r'''
int main() {
    for (float h : {0.f, 1.f, 6.f, 18.f, 128.f, 300.f, 500.f, 700.f}) {
        for (float x : {0.f, 201.f, -80.f}) {
            float y=-37.f, z=500.f, r=800.f, blur, scale;
            SkVector translate;
            SkDrawShadowMetrics::GetSpotParams(h,x,y,z,r,&blur,&scale,&translate);
            float ambient = SkDrawShadowMetrics::AmbientBlurRadius(h);
            printf("%.9g %.9g %.9g %.9g %.9g %.9g %.9g %.9g %.9g %.9g\n", h,x,y,z,r,
                ambient,ambient*SkDrawShadowMetrics::AmbientRecipAlpha(h),blur,scale,translate.fX);
            printf("%.9g\n",translate.fY);
        }
    }
    unsigned char values[128];
    // PINNED_FALLOFF_LOOP
    for (auto value : values) printf("%d ", int(value));
}
'''
with tempfile.TemporaryDirectory(prefix='zt-shadow-reference-') as temp:
    root=Path(temp)
    (root/'reference.cpp').write_text(shim+body+'}\n'+main.replace('// PINNED_FALLOFF_LOOP', loop))
    subprocess.run(['clang++','-std=c++17','-O0','-ffp-contract=off',str(root/'reference.cpp'),'-o',str(root/'reference')],check=True)
    lines=subprocess.check_output([str(root/'reference')],text=True).splitlines()
rows=[]
for i in range(0,48,2):
    row=list(map(float,lines[i].split()))+[float(lines[i+1])]
    rows.append(row)
result={'source':URL,'sha256':SHA,'falloff_source':OP_URL,'falloff_sha256':OP_SHA,'columns':['height','lightX','lightY','lightZ','lightRadius','ambientOutset','ambientBlurWidth','spotOutset','spotScale','spotX','spotY'], 'rows':rows,'falloff':list(map(int,lines[48].split()))}
output=Path(__file__).resolve().parents[1]/'ZTransferTests'/'Fixtures'/'android15-shadow-metrics.json'
output.parent.mkdir(exist_ok=True)
output.write_text(json.dumps(result,indent=2)+'\n')
print(f'{len(rows)} projections and {len(result["falloff"])} falloff bytes: {output}')

# Compile the original non-circle constructor calculations and vertex writer.
# The wrapper supplies only the types/fields the extracted source accesses.
constructor_start = op.index('        SkScalar innerRadius = 0.0f;')
constructor = op[constructor_start:op.index('        this->setBounds', constructor_start)]
writer_start = op.index('    void fillInRRectVerts(')
writer = op[writer_start:op.index('    GrProgramInfo* programInfo()', writer_start)]
indices_start = op.index('static const uint16_t gRRectIndices[]')
indices = op[indices_start:op.index('// overstroke count', indices_start)]
mesh_shim = r'''
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cassert>
#include <cstdint>
using SkScalar = float;
using GrColor = unsigned;
#define SkASSERT assert
constexpr float SK_ScalarSqrt2 = 1.4142135623730950488f;
struct SkPoint {
 float fX, fY;
 static SkPoint Make(float x,float y) { return {x,y}; }
 void normalize() { float d=std::sqrt(fX*fX+fY*fY); fX/=d; fY/=d; }
};
using SkVector = SkPoint;
struct SkRect {
 float fLeft,fTop,fRight,fBottom;
 float width() const {return fRight-fLeft;}
 float height() const {return fBottom-fTop;}
};
enum RRectType {kFill_RRectType,kStroke_RRectType,kOverstroke_RRectType};
struct Geometry {
 GrColor fColor; float fOuterRadius,fUmbraInset,fInnerRadius,fBlurRadius;
 SkRect fDevBounds; RRectType fType;
};
struct CircleVertex { SkPoint fPos; GrColor fColor; SkPoint fOffset; float fDistanceCorrection; };
struct Reference {
'''
mesh_main = r'''
};
int main() {
 for(float radius : {0.f, 4.f, 20.f}) {
  for(float blurRadius : {2.f, 12.f, 60.f}) {
   for(float insetWidth : {2.f, 16.f, 36.f, 40.f, 41.f, 100.f}) {
    SkRect devRect{-7.f,13.f,193.f,93.f}; float devRadius=radius; bool isCircle=false;
    // ORIGINAL_CONSTRUCTOR
    Geometry g{0,outerRadius,umbraInset,innerRadius,blurRadius,devRect,type};
    CircleVertex verts[28]; CircleVertex* p=verts;
    Reference{}.fillInRRectVerts(g,&p);
    printf("%.9g %.9g %.9g %d %ld\n",radius,blurRadius,insetWidth,int(type),p-verts);
    for(auto* v=verts;v<p;++v) printf("%.9g %.9g %.9g %.9g %.9g\n",v->fPos.fX,v->fPos.fY,v->fOffset.fX,v->fOffset.fY,v->fDistanceCorrection);
    int start=type==kOverstroke_RRectType?0:24;
    int end=sizeof(gRRectIndices)/sizeof(uint16_t)-(type==kFill_RRectType?0:6);
    for(int i=start;i<end;++i) printf("%d ",int(gRRectIndices[i]));
    printf("\n");
   }
  }
 }
}
'''
with tempfile.TemporaryDirectory(prefix='zt-shadow-mesh-reference-') as temp:
    root=Path(temp)
    (root/'reference.cpp').write_text(mesh_shim+writer+mesh_main.replace('// ORIGINAL_CONSTRUCTOR',constructor).replace('int main() {',indices+'\nint main() {'))
    subprocess.run(['clang++','-std=c++17','-O0','-ffp-contract=off',str(root/'reference.cpp'),'-o',str(root/'reference')],check=True)
    lines=iter(subprocess.check_output([str(root/'reference')],text=True).splitlines())
meshes=[]
for line in lines:
    radius,blur,inset,kind,count=map(float,line.split())
    vertices=[list(map(float,next(lines).split())) for _ in range(int(count))]
    meshes.append({'radius':radius,'blur':blur,'inset':inset,'kind':int(kind),'vertices':vertices,'indices':list(map(int,next(lines).split()))})
result['meshes']=meshes
output.write_text(json.dumps(result,indent=2)+'\n')
print(f'{len(meshes)} pinned round-rect meshes: {output}')

circle_start = op.index('    void fillInCircleVerts(')
circle_writer = op[circle_start:op.index('    void fillInRRectVerts(',circle_start)]
circle_indices = op[op.index('static const uint16_t gFillCircleIndices[]'):op.index('static const int kIndicesPerFillCircle')]
circle_shim = mesh_shim.replace(' void normalize()', ' SkPoint operator+(SkPoint p) const { return {fX+p.fX,fY+p.fY}; }\n void normalize()').replace(' float width()', ' float centerX() const {return float(0.5*(double(fLeft)+double(fRight)));}\n float centerY() const {return float(0.5*(double(fTop)+double(fBottom)));}\n float width()')
circle_main = r'''
};
int main() {
 for(float radius : {1.f, 6.f, 20.f, 100.f}) {
  for(float blurRadius : {2.f, 12.f, 60.f}) {
   for(float insetWidth : {0.5f, 6.f, 20.f, 100.f, 101.f}) {
    SkRect devRect{17.f-radius,-13.f-radius,17.f+radius,-13.f+radius};
    float devRadius=radius; bool isCircle=true;
    // ORIGINAL_CONSTRUCTOR
    Geometry g{0,outerRadius,umbraInset,innerRadius,blurRadius,devRect,type};
    CircleVertex verts[16]; CircleVertex* p=verts;
    bool stroked=type==kStroke_RRectType;
    Reference{}.fillInCircleVerts(g,stroked,&p);
    printf("%.9g %.9g %.9g %d %ld\n",radius,blurRadius,insetWidth,int(type),p-verts);
    for(auto* v=verts;v<p;++v) printf("%.9g %.9g %.9g %.9g %.9g\n",v->fPos.fX,v->fPos.fY,v->fOffset.fX,v->fOffset.fY,v->fDistanceCorrection);
    const auto* indices=stroked?gStrokeCircleIndices:gFillCircleIndices;
    for(int i=0;i<(stroked?48:24);++i) printf("%d ",int(indices[i]));
    printf("\n");
   }
  }
 }
}
'''
with tempfile.TemporaryDirectory(prefix='zt-shadow-circle-reference-') as temp:
    root=Path(temp)
    (root/'reference.cpp').write_text(circle_shim+circle_writer+circle_main.replace('// ORIGINAL_CONSTRUCTOR',constructor).replace('int main() {',circle_indices+'\nint main() {'))
    subprocess.run(['clang++','-std=c++17','-O0','-ffp-contract=off',str(root/'reference.cpp'),'-o',str(root/'reference')],check=True)
    lines=iter(subprocess.check_output([str(root/'reference')],text=True).splitlines())
circles=[]
for line in lines:
    radius,blur,inset,kind,count=map(float,line.split())
    vertices=[list(map(float,next(lines).split())) for _ in range(int(count))]
    circles.append({'radius':radius,'blur':blur,'inset':inset,'kind':int(kind),'vertices':vertices,'indices':list(map(int,next(lines).split()))})
result['circles']=circles
output.write_text(json.dumps(result,indent=2)+'\n')
print(f'{len(circles)} pinned circle meshes: {output}')

# Polygon preparation: compile original method bodies, with storage/type shims.
TESS_URL = 'https://android.googlesource.com/platform/external/skia/+/android-15.0.0_r1/src/utils/SkShadowTessellator.cpp?format=TEXT'
TESS_SHA = '8a59de918ebaff6c4651b445b0843253e4185ca64718afbb9bfa660bcf9b4436'
tess_data = base64.b64decode(urllib.request.urlopen(TESS_URL, timeout=30).read())
assert hashlib.sha256(tess_data).hexdigest() == TESS_SHA
tess = tess_data.decode()
helpers = tess[tess.index('static bool duplicate_pt'):tess.index('SkBaseShadowTessellator::SkBaseShadowTessellator')]
methods = tess[tess.index('bool SkBaseShadowTessellator::accumulateCentroid'):tess.index('bool SkBaseShadowTessellator::computeConvexShadow')]
line_methods = tess[tess.index('static void sanitize_point'):tess.index('void SkBaseShadowTessellator::handleLine(const SkMatrix&')]
polygon_shim = r'''
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cassert>
#include <vector>
using SkScalar=float;
constexpr float SK_Scalar1=1.f;
#define SkASSERT assert
float SkScalarRoundToScalar(float x) {return float(std::floor(double(x)+0.5));}
bool SkScalarNearlyZero(float x) {return std::abs(x)<=1.f/4096;}
float sk_ieee_float_divide(float x,float y) {return x/y;}
struct SkPoint {
 float fX=0,fY=0;
 SkPoint operator-(SkPoint p) const {return {fX-p.fX,fY-p.fY};}
 SkPoint& operator+=(SkPoint p) {fX+=p.fX;fY+=p.fY;return *this;}
 SkPoint& operator*=(float s) {fX*=s;fY*=s;return *this;}
 float cross(SkPoint p) const {return fX*p.fY-fY*p.fX;}
};
using SkVector=SkPoint;
namespace SkPointPriv {
float DistanceToSqd(SkPoint a,SkPoint b) {auto d=a-b;return d.fX*d.fX+d.fY*d.fY;}
}
class SkBaseShadowTessellator {
public:
 std::vector<SkPoint> fPathPolygon;
 SkPoint fCentroid;
 float fArea=0,fLastArea=0,fLastCross=0,fDirection=1;
 bool fIsConvex=true;
 bool accumulateCentroid(const SkPoint&,const SkPoint&);
 bool checkConvexity(const SkPoint&,const SkPoint&,const SkPoint&);
 void finishPathPolygon();
 void handleLine(const SkPoint&);
};
'''
polygon_cases = [
 [], [[0,0]], [[0,0],[1,1]], [[0,0],[1,1],[2,2],[0,0]],
 [[0,0],[10,0],[10,8],[0,8]], [[0,8],[10,8],[10,0],[0,0]],
 [[0,0],[5,0],[10,0],[10,8],[0,8],[0,0]],
 [[-0.03125,-0.09375],[4.03125,-0.09375],[4.03125,2.03125],[-0.03125,2.03125]],
 [[0,0],[0.03,0.03],[10,0],[10,8],[0,8]],
 [[0,0],[0.0625,0],[10,0],[10,8],[0,8]],
 [[0,0],[10,0],[5,3],[10,8],[0,8]],
 [[0,0],[10,8],[0,8],[10,0]],
 [[-20.01,30.03],[20.04,30.01],[20.04,50.01],[-20.01,50.03]],
 [[0,0],[10,0],[0,0],[0,8]],
]
case_text = ','.join('{' + ','.join('{'+str(x)+'f,'+str(y)+'f}' for x,y in [(float(p[0]),float(p[1])) for p in points]) + '}' for points in polygon_cases)
polygon_main = r'''
int main() {
 std::vector<std::vector<SkPoint>> cases = {CASES};
 for (const auto& points: cases) {
  SkBaseShadowTessellator t;
  for (const auto& p:points) t.handleLine(p);
  t.finishPathPolygon();
  printf("%zu %.9g %d %.9g %.9g %.9g\n",t.fPathPolygon.size(),t.fArea,int(t.fIsConvex),t.fDirection,t.fCentroid.fX,t.fCentroid.fY);
  for(const auto& p:t.fPathPolygon) printf("%.9g %.9g\n",p.fX,p.fY);
 }
}
'''.replace('CASES',case_text)
with tempfile.TemporaryDirectory(prefix='zt-shadow-polygon-reference-') as temp:
    root=Path(temp)
    (root/'reference.cpp').write_text(polygon_shim+helpers+methods+line_methods+polygon_main)
    subprocess.run(['clang++','-std=c++17','-O0','-ffp-contract=off',str(root/'reference.cpp'),'-o',str(root/'reference')],check=True)
    lines=iter(subprocess.check_output([str(root/'reference')],text=True).splitlines())
import math
polygons=[]
for original in polygon_cases:
    count,area,convex,direction,cx,cy=map(float,next(lines).split())
    points=[list(map(float,next(lines).split())) for _ in range(int(count))]
    polygons.append({'input':original,'points':points,'area':area,'convex':bool(convex),'direction':direction,
                     'centroid':[v if math.isfinite(v) else None for v in [cx,cy]]})
polygon_output=output.with_name('android15-shadow-polygons.json')
polygon_output.write_text(json.dumps({'source':TESS_URL,'sha256':TESS_SHA,'cases':polygons},indent=2)+'\n')
print(f'{len(polygons)} pinned polygon cases: {polygon_output}')

# Curve references: original recursion, distance function and Wang scalar/vector math.
def pinned(relative, digest):
    url='https://android.googlesource.com/platform/external/skia/+/android-15.0.0_r1/'+relative+'?format=TEXT'
    raw=base64.b64decode(urllib.request.urlopen(url,timeout=30).read())
    assert hashlib.sha256(raw).hexdigest()==digest
    return raw.decode()
def function(source, prefix):
    start=source.index(prefix); opening=source.index('{',start); depth=1; end=opening+1
    while depth:
        if source[end]=='{': depth+=1
        elif source[end]=='}': depth-=1
        end+=1
    return source[start:end]+'\n'
path_source=pinned('src/gpu/ganesh/geometry/GrPathUtils.cpp','1c0a78961e1866181d5f3b58f21e9766b76d6dfd9c7ae32e67f94c04ed892825')
wang_source=pinned('src/gpu/tessellate/WangsFormula.h','8168ab499d47d0a8e213608d0a305fa31bf51ac5eb2e01ec3082714f60289a1c')
point_source=pinned('src/core/SkPoint.cpp','5534efdc0a13f3e8c69d510ca2d308339673715ef5cd2bbb75ed165aaff6df2b')
curve_shim=polygon_shim[:polygon_shim.index('class SkBaseShadowTessellator')]
curve_shim=curve_shim.replace(' float cross(', ' static float DotProduct(SkPoint a,SkPoint b) {return a.fX*b.fX+a.fY*b.fY;}\n float cross(')
curve_shim+=r'''
#include <cstdint>
#include <cstring>
#include <limits>
#define AI inline
#define SkIsFinite std::isfinite
float SkScalarAve(float a,float b) {return (a+b)*0.5f;}
uint32_t SkFloat2Bits(float x) {uint32_t b;std::memcpy(&b,&x,4);return b;}
namespace SkPointPriv {
float LengthSqd(SkPoint p) {return p.fX*p.fX+p.fY*p.fY;}
float DistanceToLineSegmentBetweenSqd(const SkPoint&,const SkPoint&,const SkPoint&);
}
namespace skvx {
typedef float float2 __attribute__((ext_vector_type(2)));
struct float4 {
 float v[4];
 float4(float2 a,float2 b):v{a[0],a[1],b[0],b[1]} {}
 float4(float a,float b,float c,float d):v{a,b,c,d} {}
 float operator[](int i) const {return v[i];}
 friend float4 operator+(float4 a,float4 b) {return {a[0]+b[0],a[1]+b[1],a[2]+b[2],a[3]+b[3]};}
 friend float4 operator*(float4 a,float4 b) {return {a[0]*b[0],a[1]*b[1],a[2]*b[2],a[3]*b[3]};}
 friend float4 operator*(float a,float4 b) {return {a*b[0],a*b[1],a*b[2],a*b[3]};}
};
}
struct VectorXform {template<class T> T operator()(T p) const {return p;}};
namespace skgpu {namespace wangs_formula {
'''
wang_parts=''.join(function(wang_source,prefix) for prefix in [
 'template<int Degree> constexpr float length_term_p2', 'AI int nextlog2(', 'AI int nextlog16(',
 'AI float quadratic_p4(', 'AI float cubic_p4('])
curve_shim+=wang_parts+r'''
skvx::float2 vector(SkPoint p) {return {p.fX,p.fY};}
int quadratic_log2(float p,const SkPoint* x) {return nextlog16(quadratic_p4(p,vector(x[0]),vector(x[1]),vector(x[2])));}
int cubic_log2(float p,const SkPoint* x) {return nextlog16(cubic_p4(p,vector(x[0]),vector(x[1]),vector(x[2]),vector(x[3])));}
}}
namespace GrPathUtils {
constexpr uint32_t kMaxPointsPerCurve=1024;
uint32_t quadraticPointCount(const SkPoint[],SkScalar);
uint32_t cubicPointCount(const SkPoint[],SkScalar);
uint32_t generateQuadraticPoints(const SkPoint&,const SkPoint&,const SkPoint&,SkScalar,SkPoint**,uint32_t);
uint32_t generateCubicPoints(const SkPoint&,const SkPoint&,const SkPoint&,const SkPoint&,SkScalar,SkPoint**,uint32_t);
}
'''
curve_bodies=function(point_source,'float SkPointPriv::DistanceToLineSegmentBetweenSqd')
curve_bodies+='static const SkScalar kMinCurveTol = 0.0001f;\n'+function(path_source,'static float tolerance_to_wangs_precision')+function(path_source,'uint32_t max_bezier_vertices')
curve_bodies+=path_source[path_source.index('uint32_t GrPathUtils::quadraticPointCount'):path_source.index('void GrPathUtils::QuadUVMatrix::set')]
curve_cases=[[[0,0],[10,20],[30,0]],[[0,0],[0,0],[0,0]],[[0,0],[20,0],[10,0]],
 [[-40,12],[0,-180],[90,15]],[[0,0],[1,0.2],[2,0]],
 [[0,0],[10,40],[20,-40],[30,0]],[[0,0],[0,0],[0,0],[0,0]],
 [[10,10],[-20,80],[200,90],[-40,-20]],[[0,0],[1e5,1e6],[2e5,-1e6],[3e5,0]]]
curve_cases.append([[0,0],[1e30,1e30],[2e30,3e30]])
case_text=','.join('{'+','.join('{'+str(float(x))+'f,'+str(float(y))+'f}' for x,y in pts)+'}' for pts in curve_cases)
curve_main=r'''
int main() {
 std::vector<std::vector<SkPoint>> cases={CASES};
 for(const auto& p:cases) {
  SkPoint output[1024];SkPoint* cursor=output;uint32_t count=0,limit=0;
  if(p.size()==3) {
   auto u=p[1]-p[0],v=p[2]-p[0];
   if(!SkScalarNearlyZero(u.cross(v))) {
    limit=GrPathUtils::quadraticPointCount(p.data(),0.2f);
    count=GrPathUtils::generateQuadraticPoints(p[0],p[1],p[2],0.2f*0.2f,&cursor,limit);
   }
  } else {
   limit=GrPathUtils::cubicPointCount(p.data(),0.2f);
   count=GrPathUtils::generateCubicPoints(p[0],p[1],p[2],p[3],0.2f*0.2f,&cursor,limit);
  }
  printf("%u %u\n",count,limit);
  for(uint32_t i=0;i<count;++i)printf("%.9g %.9g\n",output[i].fX,output[i].fY);
 }
}
'''.replace('CASES',case_text)
with tempfile.TemporaryDirectory(prefix='zt-shadow-curve-reference-') as temp:
    root=Path(temp);(root/'reference.cpp').write_text(curve_shim+curve_bodies+curve_main)
    subprocess.run(['clang++','-std=c++17','-O0','-ffp-contract=off',str(root/'reference.cpp'),'-o',str(root/'reference')],check=True)
    lines=iter(subprocess.check_output([str(root/'reference')],text=True).splitlines())
curves=[]
for original in curve_cases:
    count,limit=map(int,next(lines).split())
    curves.append({'input':original,'limit':limit,'points':[list(map(float,next(lines).split())) for _ in range(count)]})
curve_output=output.with_name('android15-shadow-curves.json')
curve_output.write_text(json.dumps({'cases':curves},indent=2)+'\n')
print(f'{len(curves)} pinned curve cases: {curve_output}')

geometry=pinned('src/core/SkGeometry.cpp','df602fce642f871af2207297577baa21551307bea15c7a549fb6cc2c1ccf2da7')
conic_shim=curve_shim.replace(' float cross(', ' bool isFinite() const {return std::isfinite(fX)&&std::isfinite(fY);}\n float cross(')
conic_shim+=r'''
#define SK_RESTRICT
#define SkDEBUGCODE(...) __VA_ARGS__
#define SkDebugf printf
#define kMaxConicToQuadPOW2 5
constexpr float SK_ScalarHalf=0.5f;
float SkScalarSqrt(float x) {return std::sqrt(x);}
float SkScalarInvert(float x) {return 1.f/x;}
float SkScalarLog2(float x) {return std::log2(x);}
int SkScalarCeilToInt(float x) {return int(std::ceil(x));}
float SkTAbs(float x) {return std::abs(x);}
using float2=skvx::float2;
float2 from_point(SkPoint p) {return {p.fX,p.fY};}
SkPoint to_point(float2 p) {return {p[0],p[1]};}
namespace SkPointPriv {
bool AreFinite(const SkPoint* p,int n) {for(int i=0;i<n;++i)if(!p[i].isFinite())return false;return true;}
bool EqualsWithinTolerance(SkPoint a,SkPoint b) {auto d=a-b;return !d.isFinite() || !(d.fX || d.fY);}
}
struct SkConic {
 SkPoint fPts[3];float fW;
 void chop(SkConic*) const;
 int computeQuadPOW2(float) const;
 int chopIntoQuadsPOW2(SkPoint*,int) const;
};
'''
error_macro=geometry[geometry.index('#define AS_QUAD_ERROR_SETUP'):geometry.index('void SkConic::computeAsQuadError')]
modern=geometry[geometry.index('#else\nvoid SkConic::chop'):]
conic_bodies=error_macro+function(geometry,'static SkScalar subdivide_w_value')+function(modern,'void SkConic::chop')
conic_bodies+=function(geometry,'int SkConic::computeQuadPOW2')+function(geometry,'static bool between')+function(geometry,'static SkPoint* subdivide')+function(geometry,'int SkConic::chopIntoQuadsPOW2')
conic_cases=[]
for radius in [0.1,1,22,1000]:
    for weight in [0,0.7071067811865476,1,2]:
        conic_cases.append({'points':[[0,0],[radius,0],[radius,radius]],'weight':weight})
conic_cases += [
 {'points':[[-20,30],[40,-90],[100,50]],'weight':0.7071067811865476},
 {'points':[[0,0],[1e6,1e6],[2e6,0]],'weight':1e20},
 {'points':[[1,2],[1,2],[1,2]],'weight':0.7071067811865476}]
case_text=','.join('{{'+','.join('{'+str(float(x))+'f,'+str(float(y))+'f}' for x,y in case['points'])+'},'+str(float(case['weight']))+'f}' for case in conic_cases)
conic_main=r'''
int main() {
 std::vector<SkConic> cases={CASES};
 for(const auto& conic:cases) {
  SkPoint quads[65];int level=conic.computeQuadPOW2(0.25f);
  int count=conic.chopIntoQuadsPOW2(quads,level);
  printf("%d %d\n",level,2*count+1);
  for(int i=0;i<2*count+1;++i)printf("%.9g %.9g\n",quads[i].fX,quads[i].fY);
  std::vector<SkPoint> line;
  SkPoint last=quads[0];
  for(int i=0;i<count;++i) {
   SkPoint pts[3]={last,quads[2*i+1],i==count-1?conic.fPts[2]:quads[2*i+2]};
   auto u=pts[1]-pts[0],v=pts[2]-pts[0];
   if(!SkScalarNearlyZero(u.cross(v))) {
    SkPoint buffer[1024];SkPoint* cursor=buffer;
    int limit=GrPathUtils::quadraticPointCount(pts,0.2f);
    int n=GrPathUtils::generateQuadraticPoints(pts[0],pts[1],pts[2],0.2f*0.2f,&cursor,limit);
    line.insert(line.end(),buffer,buffer+n);
   }
   last=pts[2];
  }
  printf("%zu\n",line.size());
  for(const auto& p:line)printf("%.9g %.9g\n",p.fX,p.fY);
 }
}
'''.replace('CASES',case_text)
with tempfile.TemporaryDirectory(prefix='zt-shadow-conic-reference-') as temp:
    root=Path(temp);(root/'reference.cpp').write_text(conic_shim+curve_bodies+conic_bodies+conic_main)
    subprocess.run(['clang++','-std=c++17','-O0','-ffp-contract=off',str(root/'reference.cpp'),'-o',str(root/'reference')],check=True)
    lines=iter(subprocess.check_output([str(root/'reference')],text=True).splitlines())
conics=[]
for case in conic_cases:
    level,count=map(int,next(lines).split())
    quads=[list(map(float,next(lines).split())) for _ in range(count)]
    count=int(next(lines));line=[list(map(float,next(lines).split())) for _ in range(count)]
    conics.append({**case,'level':level,'quads':quads,'line':line})
conic_output=output.with_name('android15-shadow-conics.json')
conic_output.write_text(json.dumps({'cases':conics},indent=2)+'\n')
print(f'{len(conics)} pinned conic cases: {conic_output}')

# Convex umbra collapse: original adjustment block and packed-color arithmetic.
color_source=pinned('include/private/SkColorData.h','891d30482d4e9c3cbec207c9a320cf918d5169b50d0be931ee73f32f8aac3564')
color_bodies='\n'.join(function(color_source,prefix) for prefix in [
    'static inline uint64_t SkSplay(uint32_t color)',
    'static inline uint32_t SkUnsplay(uint64_t agrb)',
    'static inline SkPMColor SkFastFourByteInterp256_64'])
start=tess.index('    auto umbraColor = kUmbraColor;',tess.index('bool SkBaseShadowTessellator::computeConvexShadow'))
end=tess.index('        // generate inner ring',start)
block=tess[start:end].replace('    SkRect bounds;\n    bounds.setBounds(&fPathPolygon[0], fPathPolygon.size());\n','').replace('    SkTDArray<SkPoint> insetPolygon;\n','')+'    }\n'
umbra_shim=curve_shim+function(point_source,'float SkPointPriv::DistanceToLineSegmentBetweenSqd')+r'''
using SkPMColor=uint32_t;
constexpr float SK_ScalarNearlyZero=1.f/4096;
constexpr SkPMColor kUmbraColor=0xff000000, kPenumbraColor=0;
float SkScalarSqrt(float x) { return std::sqrt(x); }
'''+color_bodies+r'''
SkPMColor SkPMLerp(SkPMColor a,SkPMColor b,unsigned s) {return SkFastFourByteInterp256_64(a,b,s);}
void emit(const std::vector<SkPoint>& fPathPolygon,SkPoint fCentroid,float inset) {
'''+block+r'''
 printf("%.9g %u\n",inset,umbraColor>>24);
}
int main() {
'''
umbra_cases=[]
for polygon in polygons:
    if not polygon['convex'] or len(polygon['points'])<3 or None in polygon['centroid']:
        continue
    for inset in [0,1/8192,1/4096,0.01,0.1,0.49,0.5,1,5,10,20,100,10000]:
        umbra_cases.append({'points':polygon['points'],'centroid':polygon['centroid'],'inset':inset})
for case in umbra_cases:
    points=','.join('{'+','.join(str(float(v))+'f' for v in p)+'}' for p in case['points'])
    centroid='{'+','.join(str(float(v))+'f' for v in case['centroid'])+'}'
    umbra_shim+=f'emit({{{points}}},{centroid},{float(case["inset"])}f);\n'
umbra_shim+='}\n'
with tempfile.TemporaryDirectory(prefix='zt-shadow-umbra-reference-') as temp:
    root=Path(temp);(root/'reference.cpp').write_text(umbra_shim)
    subprocess.run(['clang++','-std=c++17','-O0','-ffp-contract=off',str(root/'reference.cpp'),'-o',str(root/'reference')],check=True)
    lines=subprocess.check_output([str(root/'reference')],text=True).splitlines()
for case,line in zip(umbra_cases,lines):
    inset,alpha=line.split();case.update(adjustedInset=float(inset),alpha=int(alpha))
assert len(lines)==len(umbra_cases)
umbra_output=output.with_name('android15-shadow-umbra.json')
umbra_output.write_text(json.dumps({'cases':umbra_cases},indent=2)+'\n')
print(f'{len(umbra_cases)} pinned umbra cases: {umbra_output}')

# Convex inset: unmodified SkPolyUtils algorithm, including edge removal,
# segment intersection, convexity and SkPoint's Double normalization.
poly_source=pinned('src/utils/SkPolyUtils.cpp','85ab2e03b19b24d0cb94b4a8ce501fd04d13739cbcc7918542c31233fddb6451')
inset_shim=r'''
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cassert>
#include <vector>
#include <limits>
#include <cstdint>
using SkScalar=float;
constexpr float SK_ScalarNearlyZero=1.f/4096,SK_Scalar1=1;
constexpr float SK_ScalarMax=std::numeric_limits<float>::max(),SK_ScalarMin=-SK_ScalarMax;
#define SkASSERT assert
bool SkIsFinite(float x) {return std::isfinite(x);}
bool SkIsFinite(float x,float y) {return std::isfinite(x)&&std::isfinite(y);}
bool SkScalarNearlyZero(float x,float tolerance=SK_ScalarNearlyZero) {return std::abs(x)<=tolerance;}
float SkScalarAbs(float x) {return std::abs(x);}
double sk_ieee_double_divide(double x,double y) {return x/y;}
float sk_double_to_float(double x) {return float(x);}
struct SkPoint {
 float fX=0,fY=0;
 static SkPoint Make(float x,float y) {return {x,y};}
 void set(float x,float y) {fX=x;fY=y;}
 bool isFinite() const {return SkIsFinite(fX,fY);}
 SkPoint operator+(SkPoint p) const {return {fX+p.fX,fY+p.fY};}
 SkPoint operator-(SkPoint p) const {return {fX-p.fX,fY-p.fY};}
 SkPoint operator-() const {return {-fX,-fY};}
 SkPoint operator*(float s) const {return {fX*s,fY*s};}
 float dot(SkPoint p) const {return fX*p.fX+fY*p.fY;}
 float cross(SkPoint p) const {return fX*p.fY-fY*p.fX;}
 bool setLength(float length);
};
using SkVector=SkPoint;
template<int N,class T> struct AutoSTMalloc {
 std::vector<T> data;
 AutoSTMalloc(int count):data(count) {}
 T& operator[](int index) {return data[index];}
};
template<class T> struct SkTDArray {
 std::vector<T> data;
 T* append() {data.emplace_back();return &data.back();}
 void reset() {data.clear();}
 void reserve(int n) {data.reserve(n);}
 void pop_back() {data.pop_back();}
 T& operator[](int index) {return data[index];}
 T* begin() {return data.data();}
 int size() const {return int(data.size());}
};
'''
inset_shim+=function(point_source,'template <bool use_rsqrt> bool set_point_length')
inset_shim+='bool SkPoint::setLength(float length) {return set_point_length<false>(this,fX,fY,length);}\n'
priv_source=pinned('src/core/SkPointPriv.h','337cdbde10fc08d9238dc19b97ea0a3e9af0ff57f038c72377f2817ab4195e04')
inset_shim+='namespace SkPointPriv {\n'+function(priv_source,'static bool CanNormalize')
inset_shim+=function(priv_source,'static bool EqualsWithinTolerance(const SkPoint& p1')
inset_shim+=function(priv_source,'static bool EqualsWithinTolerance(const SkPoint& pt, const SkPoint& p, SkScalar tol)')+'}\n'
inset_shim+=poly_source[poly_source.index('struct OffsetSegment'):poly_source.index('// Compute difference vector')]
for prefix in ['static inline bool outside_interval','static inline bool zero_length','static bool compute_intersection','bool SkIsConvexPolygon']:
    inset_shim+=function(poly_source,prefix)
start=poly_source.index('struct OffsetEdge {');end=poly_source.index('static void remove_node',start)
inset_shim+=poly_source[start:end]+function(poly_source,'static void remove_node')+function(poly_source,'bool SkInsetConvexPolygon')
inset_inputs=polygon_cases+[
 [[0,0],[100,0],[100,1],[0,1]],
 [[0,0],[100,0],[100,80],[0,80]],
 [[0,0],[9,0],[10,1],[10,10],[0,10]],
 [[0,0],[10,0],[5,1]],
 [[0,0],[10,0],[10,10],[0,10],[0,0]],
 [[0,0],[0,0],[10,0],[10,10],[0,10]],
 [[0,0],[1,0],[2,0]],
]
# Sample a rotated rounded outline and an irregular convex polygon as well as
# axis-aligned cases; the renderer's eventual arbitrary rotation depends on it.
for count in [5,8,32]:
    inset_inputs.append([[float(20+30*math.cos(i*2*math.pi/count+0.17)),float(-15+10*math.sin(i*2*math.pi/count+0.17))] for i in range(count)])
inset_cases=[]
for points in inset_inputs:
    for ring in [points,list(reversed(points))]:
        for distance in [-0.01,-1/8192,0,1/4096,0.01,0.49,0.5,1,4,5,20,100]:
            inset_cases.append({'input':ring,'inset':distance})
# Feed the previous stage's actual adjusted values to test the handoff.
for case in umbra_cases:
    inset_cases.append({'input':case['points'],'inset':case['adjustedInset']})
inset_main='int main() {\n'
for case in inset_cases:
    points=','.join('{'+','.join(str(float(v))+'f' for v in p)+'}' for p in case['input'])
    inset_main+='{std::vector<SkPoint> input={'+points+'};SkTDArray<SkPoint> out;'
    inset_main+=f'bool valid=SkInsetConvexPolygon(input.data(),int(input.size()),{float(case["inset"])}f,&out);'
    inset_main+='printf("%d %d\\n",valid,out.size());for(auto p:out.data)printf("%.9g %.9g\\n",p.fX,p.fY);}\n'
inset_main+='}\n'
with tempfile.TemporaryDirectory(prefix='zt-shadow-inset-reference-') as temp:
    root=Path(temp);(root/'reference.cpp').write_text(inset_shim+inset_main)
    subprocess.run(['clang++','-std=c++17','-O0','-ffp-contract=off',str(root/'reference.cpp'),'-o',str(root/'reference')],check=True)
    lines=iter(subprocess.check_output([str(root/'reference')],text=True).splitlines())
for case in inset_cases:
    valid,count=map(int,next(lines).split())
    case.update(valid=bool(valid),points=[list(map(float,next(lines).split())) for _ in range(count)])
inset_output=output.with_name('android15-shadow-insets.json')
inset_output.write_text(json.dumps({'cases':inset_cases},indent=2,allow_nan=False)+'\n')
print(f'{len(inset_cases)} pinned inset cases: {inset_output}')

# Full convex mesh, retaining the original tessellator bodies and clip state.
mesh_shim=inset_shim.replace(' bool setLength(float length);',r'''
 static float DotProduct(SkPoint a,SkPoint b) {return a.dot(b);}
 SkPoint& operator*=(float s) {fX*=s;fY*=s;return *this;}
 bool normalize() {return setLength(1);}
 bool setLength(float length);
''').replace(' T* append() {',r'''
 const T& operator[](int i) const {return data[i];}
 void push_back(T value) {data.push_back(value);}
 T* append(int n) {auto old=data.size();data.resize(old+n);return data.data()+old;}
 T* append() {
''')
mesh_shim+=r'''
using SkPMColor=uint32_t;
using SkColor=uint32_t;
float sk_ieee_float_divide(float x,float y) {return x/y;}
constexpr SkColor kUmbraColor=0xff000000,kPenumbraColor=0;
float SkScalarSqrt(float x) {return std::sqrt(x);}
float SkScalarATan2(float y,float x) {return std::atan2(y,x);}
float SkScalarSin(float x) {return std::sin(x);}
float SkScalarCos(float x) {return std::cos(x);}
int SkScalarRoundToInt(float x) {return int(std::floor(double(x)+0.5));}
struct SkRect {void setBounds(const SkPoint*,int) {}};
namespace SkPointPriv {
float LengthSqd(SkPoint p) {return p.dot(p);}
float DistanceToSqd(SkPoint a,SkPoint b) {return LengthSqd(a-b);}
float DistanceToLineSegmentBetweenSqd(const SkPoint&,const SkPoint&,const SkPoint&);
}
'''+function(point_source,'float SkPointPriv::DistanceToLineSegmentBetweenSqd')+color_bodies+r'''
SkPMColor SkPMLerp(SkPMColor a,SkPMColor b,unsigned s) {return SkFastFourByteInterp256_64(a,b,s);}
class SkBaseShadowTessellator {
public:
 SkTDArray<SkPoint> fPositions,fPathPolygon,fClipPolygon,fClipVectors;
 SkTDArray<SkColor> fColors;
 SkTDArray<uint16_t> fIndices;
 SkPoint fCentroid,fFirstOutset,fFirstPoint,fPrevOutset,fPrevPoint;
 float fDirection=1;
 int fFirstVertexIndex=-1,fPrevUmbraIndex=-1,fCurrUmbraIndex=0,fCurrClipIndex=0;
 bool fTransparent=false,fValidUmbra=true,fFirstUmbraOutside=false,fPrevUmbraOutside=false;
 int indexCount() const {return fIndices.size();}
 bool computeConvexShadow(float,float,bool);
 void computeClipVectorsAndTestCentroid();
 bool clipUmbraPoint(const SkPoint&,const SkPoint&,SkPoint*);
 void addEdge(const SkVector&,const SkVector&,SkColor,const SkTDArray<SkPoint>&,bool,bool);
 bool addInnerPoint(const SkPoint&,SkColor,const SkTDArray<SkPoint>&,int*);
 int getClosestUmbraIndex(const SkPoint&,const SkTDArray<SkPoint>&);
 bool addArc(const SkVector&,SkScalar,bool);
 void appendTriangle(uint16_t,uint16_t,uint16_t);
};
'''+function(poly_source,'bool SkComputeRadialSteps')+function(tess,'static bool compute_normal')+function(tess,'static bool duplicate_pt')
for prefix in ['bool SkBaseShadowTessellator::computeConvexShadow',
 'void SkBaseShadowTessellator::computeClipVectorsAndTestCentroid',
 'void SkBaseShadowTessellator::addEdge','bool SkBaseShadowTessellator::clipUmbraPoint',
 'bool SkBaseShadowTessellator::addInnerPoint','int SkBaseShadowTessellator::getClosestUmbraIndex',
 'bool SkBaseShadowTessellator::addArc','void SkBaseShadowTessellator::appendTriangle']:
    mesh_shim+=function(tess,prefix)
mesh_polygons=[p for p in polygons if p['convex'] and len(p['points'])>=3 and None not in p['centroid']]
for count in [3,8,32]:
    ring=[[30*math.cos(i*2*math.pi/count+0.17),10*math.sin(i*2*math.pi/count+0.17)] for i in range(count)]
    mesh_polygons.append({'points':ring,'centroid':[0,0],'direction':-1})
mesh_polygons.append({'points':[[0,0],[100,0.0625],[100.0625,0.0625]],'centroid':[200.0625/3,0.125/3],'direction':-1})
mesh_cases=[]
for polygon in mesh_polygons:
    for inset in [0,0.1,5,20]:
        for outset in [0.1,6,32]:
            for transparent in [False,True]:
                for clip_offset in [None,0,30,"half"]:
                    if clip_offset == "half":
                        clip=[[(p[i]+polygon["centroid"][i])*0.5 for i in range(2)] for p in polygon["points"]]
                    else:
                        clip=None if clip_offset is None else [[p[0]+clip_offset,p[1]] for p in polygon['points']]
                    mesh_cases.append({'points':polygon['points'],'centroid':polygon['centroid'],
                        'direction':polygon['direction'],'inset':inset,'outset':outset,'transparent':transparent,'clip':clip})
def cpp_points(points):
    return '{'+','.join('{'+','.join(str(float(v))+'f' for v in p)+'}' for p in points)+'}'
mesh_main='int main() {\n'
for case in mesh_cases:
    mesh_main+='{SkBaseShadowTessellator t;'
    mesh_main+='t.fPathPolygon.data='+cpp_points(case['points'])+';'
    mesh_main+='t.fCentroid='+cpp_points([case['centroid']])[1:-1]+';'
    mesh_main+=f't.fDirection={float(case["direction"])}f;t.fTransparent={int(case["transparent"])};'
    if case['clip'] is not None: mesh_main+='t.fClipPolygon.data='+cpp_points(case['clip'])+';'
    mesh_main+=f'bool valid=t.computeConvexShadow({float(case["inset"])}f,{float(case["outset"])}f,{int(case["clip"] is not None)});'
    mesh_main+='printf("%d %d %d\\n",valid,t.fPositions.size(),t.fIndices.size());'
    mesh_main+='for(int i=0;i<t.fPositions.size();++i)printf("%.9g %.9g %u\\n",t.fPositions[i].fX,t.fPositions[i].fY,t.fColors[i]>>24);'
    mesh_main+='for(auto i:t.fIndices.data)printf("%u ",i);printf("\\n");}\n'
mesh_main+='}\n'
with tempfile.TemporaryDirectory(prefix='zt-shadow-convex-reference-') as temp:
    root=Path(temp);(root/'reference.cpp').write_text(mesh_shim+mesh_main)
    subprocess.run(['clang++','-std=c++17','-O0','-ffp-contract=off',str(root/'reference.cpp'),'-o',str(root/'reference')],check=True)
    lines=iter(subprocess.check_output([str(root/'reference')],text=True).splitlines())
for case in mesh_cases:
    valid,count,index_count=map(int,next(lines).split())
    vertices=[list(map(float,next(lines).split())) for _ in range(count)]
    indices=list(map(int,next(lines).split()))
    assert len(indices)==index_count
    case.update(valid=bool(valid),vertices=vertices,indices=indices)
mesh_output=output.with_name('android15-shadow-convex-meshes.json')
mesh_output.write_text(json.dumps({'cases':mesh_cases},indent=2,allow_nan=False)+'\n')
print(f'{len(mesh_cases)} pinned convex meshes: {mesh_output}')

# Path assembly: original force-close iterator, tessellator handlers and matrix
# mapping. Storage and type dispatch are shims; geometry bodies are extracted.
matrix_source=pinned('src/core/SkMatrix.cpp','83eece5b45e4090b053dbc7829d6c3df86fb4b9624379972d7dd0d5c8c4965f8')
skpath_source=pinned('src/core/SkPath.cpp','fdb522e724ba6af95b1dc572be742cc2956be44a48b8b35c8de2cc2a25555fd4')
assembly_shim=conic_shim.replace('struct SkConic {','class SkMatrix;\nstruct SkConic {\n static float TransformW(const SkPoint[],float,const SkMatrix&);')
assembly_shim=assembly_shim.replace(' float cross(', ' bool operator!=(SkPoint p) const {return fX!=p.fX || fY!=p.fY;}\n float cross(')
assembly_shim+=curve_bodies+conic_bodies+r'''
#define SK_GANESH
#define SkIsNaN std::isnan
#define SkDEBUGFAIL(x) assert(false)
float sk_double_to_float(double x) {return float(x);}
double sk_ieee_double_divide(double x,double y) {return x/y;}
struct SkPoint3 {float fX,fY,fZ;void set(float x,float y,float z) {fX=x;fY=y;fZ=z;}};
class SkMatrix {
public:
 enum {kMScaleX,kMSkewX,kMTransX,kMSkewY,kMScaleY,kMTransY,kMPersp0,kMPersp1,kMPersp2};
 enum {kTranslate_Mask=1,kScale_Mask=2,kAffine_Mask=4,kPerspective_Mask=8};
 float fMat[9];
 bool hasPerspective() const {return fMat[6]!=0 || fMat[7]!=0 || fMat[8]!=1;}
 int getType() const {
  int mask=0;if(fMat[2]!=0 || fMat[5]!=0)mask|=1;
  if(fMat[0]!=1 || fMat[4]!=1)mask|=2;
  if(fMat[1]!=0 || fMat[3]!=0)mask|=4;
  if(hasPerspective())mask|=8;return mask;
 }
 bool isIdentity() const {return getType()==0;}
 static void Persp_pts(const SkMatrix&,SkPoint*,const SkPoint*,int);
 static void RotTrans_xy(const SkMatrix&,float,float,SkPoint*);
 static void ScaleTrans_xy(const SkMatrix&,float,float,SkPoint*);
 static void Trans_xy(const SkMatrix&,float,float,SkPoint*);
 static void Identity_xy(const SkMatrix&,float,float,SkPoint*);
 void mapPoints(SkPoint* dst,const SkPoint* src,int count) const {
  if(hasPerspective()) {Persp_pts(*this,dst,src,count);return;}
  for(int i=0;i<count;++i) {
   if(getType()&4) RotTrans_xy(*this,src[i].fX,src[i].fY,dst+i);
   else if(getType()&2) ScaleTrans_xy(*this,src[i].fX,src[i].fY,dst+i);
   else if(getType()&1) Trans_xy(*this,src[i].fX,src[i].fY,dst+i);
   else Identity_xy(*this,src[i].fX,src[i].fY,dst+i);
  }
 }
 void mapPoints(SkPoint* p,int count) const {mapPoints(p,p,count);}
 void mapHomogeneousPoints(SkPoint3*,const SkPoint3*,int) const;
};
struct SkMatrixPriv {
 static void MapHomogeneousPointsWithStride(const SkMatrix&,SkPoint3*,size_t,const SkPoint3*,size_t,int);
};
'''
start=matrix_source.index('static inline SkScalar sdot(');end=matrix_source.index('static inline SkScalar scross(',start)
assembly_shim+=matrix_source[start:end]
for prefix in ['void SkMatrix::Persp_pts','void SkMatrix::RotTrans_xy','void SkMatrix::ScaleTrans_xy','void SkMatrix::Trans_xy','void SkMatrix::Identity_xy','void SkMatrixPriv::MapHomogeneousPointsWithStride','void SkMatrix::mapHomogeneousPoints(SkPoint3 dst[], const SkPoint3 src[]']:
    assembly_shim+=function(matrix_source,prefix)
assembly_shim+=function(geometry,'static void ratquad_mapTo3D')+function(geometry,'SkScalar SkConic::TransformW')
assembly_shim+=r'''
struct SkAutoConicToQuads {
 SkPoint buffer[65];int count;
 const SkPoint* computeQuads(const SkPoint p[3],float w,float tolerance) {
  SkConic c={{p[0],p[1],p[2]},w};
  count=c.chopIntoQuadsPOW2(buffer,c.computeQuadPOW2(tolerance));return buffer;
 }
 int countQuads() const {return count;}
};
template<class T> struct SkTDArray {
 std::vector<T> data;
 void reserve(int n) {data.reserve(n);}
 void resize(int n) {data.resize(n);}
 void push_back(T v) {data.push_back(v);}
 void pop_back() {data.pop_back();}
 bool empty() const {return data.empty();}
 int size() const {return int(data.size());}
 T* begin() {return data.data();}
 T& operator[](int n) {return data[n];}
};
struct SkPath {
 enum Verb {kMove_Verb,kLine_Verb,kQuad_Verb,kConic_Verb,kCubic_Verb,kClose_Verb,kDone_Verb};
 std::vector<uint8_t> verbs;std::vector<SkPoint> points;std::vector<float> weights={0};
 int countPoints() const {return int(points.size());}
 struct Iter {
  const uint8_t *fVerbs,*fVerbStop;const SkPoint* fPts;const float* fConicWeights;
  SkPoint fLastPt={0,0},fMoveTo={0,0};bool fForceClose,fNeedClose=false,fCloseLine=false;
  Iter(const SkPath& p,bool close):fVerbs(p.verbs.data()),fVerbStop(p.verbs.data()+p.verbs.size()),fPts(p.points.data()),fConicWeights(p.weights.data()),fForceClose(close) {}
  Verb autoClose(SkPoint[]);Verb next(SkPoint[]);
  float conicWeight() const {return *fConicWeights;}
 };
};
class SkBaseShadowTessellator {
public:
 SkTDArray<SkPoint> fPathPolygon,fPointBuffer;
 SkPoint fCentroid={0,0};
 float fArea=0,fLastArea=0,fLastCross=0,fDirection=1;
 bool fIsConvex=true;
 bool accumulateCentroid(const SkPoint&,const SkPoint&);
 bool checkConvexity(const SkPoint&,const SkPoint&,const SkPoint&);
 void finishPathPolygon();
 void handleLine(const SkPoint&);
 void handleLine(const SkMatrix&,SkPoint*);
 void handleQuad(const SkPoint[]);
 void handleQuad(const SkMatrix&,SkPoint[]);
 void handleCubic(const SkMatrix&,SkPoint[]);
 void handleConic(const SkMatrix&,SkPoint[],float);
};
class SkAmbientShadowTessellator:public SkBaseShadowTessellator {
public: bool computePathPolygon(const SkPath&,const SkMatrix&);
};
class SkSpotShadowTessellator:public SkBaseShadowTessellator {
public: SkTDArray<SkPoint> fClipPolygon;
 bool computeClipAndPathPolygons(const SkPath&,const SkMatrix&,const SkMatrix&);
 void addToClip(const SkPoint&);
};
constexpr float kQuadTolerance=0.2f,kCubicTolerance=0.2f,kConicTolerance=0.25f;
constexpr float kQuadToleranceSqd=kQuadTolerance*kQuadTolerance,kCubicToleranceSqd=kCubicTolerance*kCubicTolerance;
'''
assembly_shim+=function(skpath_source,'SkPath::Verb SkPath::Iter::autoClose')+function(skpath_source,'SkPath::Verb SkPath::Iter::next')
assembly_shim+=function(tess,'static bool duplicate_pt')+function(tess,'static SkScalar perp_dot')+methods+line_methods
for prefix in ['void SkBaseShadowTessellator::handleLine(const SkMatrix&', 'void SkBaseShadowTessellator::handleQuad(const SkPoint', 'void SkBaseShadowTessellator::handleQuad(const SkMatrix&','void SkBaseShadowTessellator::handleCubic','void SkBaseShadowTessellator::handleConic','bool SkAmbientShadowTessellator::computePathPolygon','bool SkSpotShadowTessellator::computeClipAndPathPolygons','void SkSpotShadowTessellator::addToClip']:
    assembly_shim+=function(tess,prefix)
# Verbs carry their stored path points, not pre-expanded curve starts.
assembly_paths=[
 [],[[0,[[1,2]]]],
 [[0,[[0,0]]],[1,[[40,0]]],[1,[[40,20]]],[1,[[0,20]]]],
 [[0,[[0,0]]],[1,[[40,0]]],[1,[[40,20]]],[1,[[0,20]]],[5,[]]],
 [[0,[[0,0]]],[2,[[20,-30],[40,0]]],[1,[[20,30]]]],
 [[0,[[0,0]]],[4,[[20,-30],[50,70],[80,0]]],[1,[[0,50]]],[5,[]]],
 [[0,[[0,0]]],[3,[[20,0],[20,20]],0.7071067811865476],[1,[[0,20]]],[5,[]]],
 [[0,[[0,0]]],[3,[[20,0],[20,20]],2],[2,[[0,30],[0,0]]],[5,[]]],
 [[0,[[0,0]]],[2,[[20,0],[40,0]]],[1,[[0,20]]],[5,[]]],
 [[0,[[0,0]]],[1,[[40,0]]],[1,[[0,40]]],[5,[]],[0,[[100,100]]]],
 [[0,[[0,0]]],[1,[[40,0]]],[1,[[0,40]]],[0,[[100,100]]],[1,[[120,120]]]],
 [[0,[[0,0]]],[1,[[40,0]]],[5,[]],[1,[[0,40]]]],
]
assembly_matrices=[[1,0,0,0,1,0,0,0,1],[1,0,17,0,1,-3,0,0,1],
 [0.8,-0.6,7,0.6,0.8,-11,0,0,1],[1.4,0.3,-19,-0.2,0.6,27,0,0,1],
 [1,0.2,4,-0.1,1,7,0.002,-0.001,1],[1,0,0,0,1,0,0,0,2]]
assembly_cases=[]
for path in assembly_paths:
 for matrix in assembly_matrices:
  for clip in [None,[0.9,-0.1,3,0.1,0.9,-5,0,0,1]]:
   assembly_cases.append({'elements':path,'matrix':matrix,'clipMatrix':clip})
assembly_main=r'''
void emit(bool valid,SkBaseShadowTessellator& t,const SkTDArray<SkPoint>* clip) {
 printf("%d %d %d %.9g %.9g %.9g %.9g %d\n",valid,t.fPathPolygon.size(),t.fIsConvex,t.fArea,t.fDirection,t.fCentroid.fX,t.fCentroid.fY,clip?clip->size():0);
 for(auto p:t.fPathPolygon.data)printf("%.9g %.9g\n",p.fX,p.fY);
 if(clip)for(auto p:clip->data)printf("%.9g %.9g\n",p.fX,p.fY);
}
int main() {
'''
for case in assembly_cases:
    verbs=[e[0] for e in case['elements']]; points=[p for e in case['elements'] for p in e[1]]
    weights=[e[2] for e in case['elements'] if e[0]==3]
    assembly_main+='{SkPath p;p.verbs={'+','.join(map(str,verbs))+'};p.points='+cpp_points(points)+';p.weights={0,'+','.join(str(float(w))+'f' for w in weights)+'};'
    assembly_main+='SkMatrix matrix={{'+','.join(str(float(v))+'f' for v in case['matrix'])+'}};'
    if case['clipMatrix'] is None:
        assembly_main+='SkAmbientShadowTessellator t;bool valid=t.computePathPolygon(p,matrix);emit(valid,t,nullptr);}\n'
    else:
        assembly_main+='SkMatrix clip={{'+','.join(str(float(v))+'f' for v in case['clipMatrix'])+'}};SkSpotShadowTessellator t;bool valid=t.computeClipAndPathPolygons(p,clip,matrix);emit(valid,t,&t.fClipPolygon);}\n'
assembly_main+='}\n'
with tempfile.TemporaryDirectory(prefix='zt-shadow-path-reference-') as temp:
    root=Path(temp);(root/'reference.cpp').write_text(assembly_shim+assembly_main)
    subprocess.run(['clang++','-std=c++17','-O0','-ffp-contract=off',str(root/'reference.cpp'),'-o',str(root/'reference')],check=True)
    lines=iter(subprocess.check_output([str(root/'reference')],text=True).splitlines())
for case in assembly_cases:
    valid,count,convex,area,direction,cx,cy,clip_count=map(float,next(lines).split())
    points=[list(map(float,next(lines).split())) for _ in range(int(count))]
    clip=[list(map(float,next(lines).split())) for _ in range(int(clip_count))]
    case.update(valid=bool(valid),points=points,convex=bool(convex),area=area,direction=direction,
                centroid=[v if math.isfinite(v) else None for v in [cx,cy]],clip=clip)
assembly_output=output.with_name('android15-shadow-paths.json')
assembly_output.write_text(json.dumps({'cases':assembly_cases},indent=2,allow_nan=False)+'\n')
print(f'{len(assembly_cases)} pinned path assembly cases: {assembly_output}')

# Spot projection with the original matrix concatenation and light projection.
shadow_info=pinned('src/core/SkDrawShadowInfo.cpp','959f431fb27027b7f558ef845618ba14408604adbc5f6d021d6a1ba43a4b8d36')
projection_shim=assembly_shim.replace('class SkMatrix {\npublic:',r'''
struct SkRect;
class SkMatrix {
public:
 using TypeMask=unsigned;
 enum {kUnknown_Mask=16,kOnlyPerspectiveValid_Mask=32};
 void setTypeMask(unsigned) {}
 bool isTriviallyIdentity() const {return isIdentity();}
 SkMatrix& setAll(float a,float b,float c,float d,float e,float f,float g,float h,float i) {
  float v[9]={a,b,c,d,e,f,g,h,i};memcpy(fMat,v,sizeof(v));return *this;
 }
 SkMatrix& setScaleTranslate(float sx,float sy,float tx,float ty) {return setAll(sx,0,tx,0,sy,ty,0,0,1);}
 SkMatrix& setConcat(const SkMatrix&,const SkMatrix&);
 SkMatrix& preConcat(const SkMatrix&);
 void mapRectToQuad(SkPoint*,const SkRect&) const;
''')
projection_shim=projection_shim.replace('struct SkPoint3 {float fX,fY,fZ;',r'''
struct SkPoint3 {float fX,fY,fZ;
 SkPoint3 cross(SkPoint3 p) const {return {fY*p.fZ-fZ*p.fY,fZ*p.fX-fX*p.fZ,fX*p.fY-fY*p.fX};}
 SkPoint3 operator-(SkPoint3 p) const {return {fX-p.fX,fY-p.fY,fZ-p.fZ};}
 SkPoint3 operator-() const {return {-fX,-fY,-fZ};}
''')
projection_shim=projection_shim.replace(' bool operator!=(SkPoint p)', ' static SkPoint Make(float x,float y) {return {x,y};}\n bool operator!=(SkPoint p)')
projection_shim+=r'''
constexpr float SK_ScalarNearlyZero=1.f/4096;
template<class T> T SkTPin(T x,T lo,T hi) {return std::clamp(x,lo,hi);}
using SkVector3=SkPoint3;
struct SkRect {
 float fLeft,fTop,fRight,fBottom;
 float centerX() const {return float(0.5*(double(fLeft)+double(fRight)));}
 float centerY() const {return float(0.5*(double(fTop)+double(fBottom)));}
 float width() const {return fRight-fLeft;}
 float height() const {return fBottom-fTop;}
};
void SkMatrix::mapRectToQuad(SkPoint* p,const SkRect& r) const {
 SkPoint corners[4]={{r.fLeft,r.fTop},{r.fRight,r.fTop},{r.fRight,r.fBottom},{r.fLeft,r.fBottom}};
 mapPoints(p,corners,4);
}
'''
for prefix in ['static inline float muladdmul','static inline float rowcol3','static bool only_scale_and_translate','SkMatrix& SkMatrix::setConcat','SkMatrix& SkMatrix::preConcat']:
    projection_shim+=function(matrix_source,prefix)
projection_shim+=source[source.index('namespace SkDrawShadowMetrics {'):source.index('// Create the transformation')]
projection_shim+=function(shadow_info,'bool GetSpotShadowTransform')+'}\n'
projection_cases=[]
for bounds in [[0,0,100,40],[-73,21,91,87]]:
 for matrix in assembly_matrices:
  for plane in [[0,0,0],[0,0,6],[0,0,64],[0.1,-0.2,10],[0,0,500]]:
   for light in [[201,-50,500],[0,0,20]]:
    for directional in [False,True]:
     projection_cases.append({'bounds':bounds,'matrix':matrix,'plane':plane,'light':light,'radius':800,'directional':directional})
for bounds in [[0,0,0,40],[0,0,100,0],[0,0,0.0001,40]]:
 projection_cases.append({'bounds':bounds,'matrix':assembly_matrices[4],'plane':[0,0,6],'light':[20,0,500],'radius':20,'directional':False})
for plane in [[0,0,6],[1e-38,1e-38,6]]:
 projection_cases.append({'bounds':[2e38,2e38,3e38,3e38],'matrix':assembly_matrices[0],'plane':plane,'light':[201,-50,500],'radius':800,'directional':False})
projection_main='int main() {\n'
for case in projection_cases:
 matrix=','.join(str(float(v))+'f' for v in case['matrix'])
 bounds=','.join(str(float(v))+'f' for v in case['bounds'])
 plane=','.join(str(float(v))+'f' for v in case['plane'])
 light=','.join(str(float(v))+'f' for v in case['light'])
 projection_main+='{SkMatrix ctm={{'+matrix+'}},out={{1,0,0,0,1,0,0,0,1}};float radius=0;'
 projection_main+=f'bool valid=SkDrawShadowMetrics::GetSpotShadowTransform({{{light}}},{float(case["radius"])}f,ctm,{{{plane}}},{{{bounds}}},{int(case["directional"])},&out,&radius);'
 projection_main+='printf("%d %.9g ",valid,radius);for(float v:out.fMat)printf("%.9g ",v);printf("\\n");}\n'
projection_main+='}\n'
with tempfile.TemporaryDirectory(prefix='zt-shadow-projection-reference-') as temp:
 root=Path(temp);(root/'reference.cpp').write_text(projection_shim+projection_main)
 subprocess.run(['clang++','-std=c++17','-O0','-ffp-contract=off',str(root/'reference.cpp'),'-o',str(root/'reference')],check=True)
 lines=subprocess.check_output([str(root/'reference')],text=True).splitlines()
assert len(lines)==len(projection_cases)
for case,line in zip(projection_cases,lines):
 valid,radius,*matrix=map(float,line.split());case.update(valid=bool(valid),outset=radius,projected=matrix)
projection_output=output.with_name('android15-shadow-projections.json')
projection_output.write_text(json.dumps({'cases':projection_cases},indent=2,allow_nan=False)+'\n')
print(f'{len(projection_cases)} pinned spot projection cases: {projection_output}')

# Rounded rectangle paths: original SkRRect normalization, point iterators and
# SkPath construction methods, with metadata bookkeeping replaced by no-ops.
makers=pinned('src/core/SkPathMakers.h','b05e7f3c35e5a41f9ca956cc668cf3ac5c559337f61510e9156bc535071b2605')
rrect_source=pinned('src/core/SkRRect.cpp','d4a7560885b9b609e70b3a4734f186ebc1bf5d17a8f91f35001f925437af0c07')
rrect_shim=projection_shim.replace('struct SkPath {',r'''
enum class SkPathDirection {kCW,kCCW};
enum class SkPathFirstDirection {kCW,kCCW,kUnknown};
struct SkRRect;
namespace SkPathRef {class Editor;}
struct SkPath {
 SkPath* fPathRef=this;int fLastMoveToIndex=0;
 int countVerbs() const {return int(verbs.size());}
 int countWeights() const {return int(weights.size())-1;}
 void validate() const {}
 bool hasOnlyMoveTos() const {for(auto v:verbs)if(v!=0)return false;return true;}
 void setFirstDirection(SkPathFirstDirection) {}
 void incReserve(int,int,int) {}
 bool dirtyAfterEdit() {return true;}
 SkPath& moveTo(SkPoint p) {verbs.push_back(kMove_Verb);points.push_back(p);return *this;}
 SkPath& lineTo(SkPoint p) {verbs.push_back(kLine_Verb);points.push_back(p);return *this;}
 SkPath& conicTo(SkPoint c,SkPoint p,float w) {verbs.push_back(kConic_Verb);points.push_back(c);points.push_back(p);weights.push_back(w);return *this;}
 SkPath& close() {verbs.push_back(kClose_Verb);return *this;}
 SkPath& addRect(const SkRect&,SkPathDirection,unsigned);
 SkPath& addOval(const SkRect&,SkPathDirection,unsigned);
 SkPath& addRRect(const SkRRect&,SkPathDirection);
 SkPath& addRRect(const SkRRect&,SkPathDirection,unsigned);
''')
rrect_shim=rrect_shim.replace('float centerX() const {',r'''
 bool isFinite() const {return std::isfinite(fLeft)&&std::isfinite(fTop)&&std::isfinite(fRight)&&std::isfinite(fBottom);}
 bool isEmpty() const {return fLeft>=fRight || fTop>=fBottom;}
 SkRect makeSorted() const {return {std::min(fLeft,fRight),std::min(fTop,fBottom),std::max(fLeft,fRight),std::max(fTop,fBottom)};}
 float centerX() const {
''')
rrect_shim=rrect_shim.replace(' static SkPoint Make(float x,float y)', ' void set(float x,float y) {fX=x;fY=y;}\n static SkPoint Make(float x,float y)')
rrect_shim+=r'''
#undef SkIsFinite
bool SkIsFinite(float x,float y) {return std::isfinite(x)&&std::isfinite(y);}
float SkScalarHalf(float x) {return x*0.5f;}
constexpr float SK_ScalarRoot2Over2=0.707106781f;
struct SkRRect {
 enum {kEmpty_Type,kRect_Type,kSimple_Type,kOval_Type};
 enum Corner {kUpperLeft_Corner,kUpperRight_Corner,kLowerRight_Corner,kLowerLeft_Corner};
 SkRect fRect={0,0,0,0};SkPoint fRadii[4]={};int fType=kEmpty_Type;
 bool initializeRect(const SkRect&);
 void setRectXY(const SkRect&,float,float);
 void setRect(const SkRect& r) {if(initializeRect(r)){memset(fRadii,0,sizeof(fRadii));fType=kRect_Type;}}
 const SkRect& getBounds() const {return fRect;}
 SkPoint radii(Corner c) const {return fRadii[c];}
 bool isRect() const {return fType==kRect_Type;}
 bool isEmpty() const {return fType==kEmpty_Type;}
 bool isOval() const {return fType==kOval_Type;}
 bool isValid() const {return true;}
};
struct SkAutoDisableDirectionCheck {SkAutoDisableDirectionCheck(SkPath*) {}};
struct SkAutoPathBoundsUpdate {SkAutoPathBoundsUpdate(SkPath*,const SkRect&) {}};
namespace SkPathRef {
class Editor {
 SkPath* path;
public:
 Editor(SkPath** p,int=0,int=0):path(*p) {}
 SkPoint* growForVerb(int verb) {path->verbs.push_back(verb);path->points.emplace_back();return &path->points.back();}
 void setIsRRect(bool,unsigned) {}
 void setIsOval(bool,unsigned,bool) {}
};
}
'''
rrect_shim+=function(rrect_source,'bool SkRRect::initializeRect')+function(rrect_source,'void SkRRect::setRectXY')
rrect_shim+=makers[makers.index('template <unsigned N>'):makers.rindex('#endif')]
for prefix in ['static void assert_known_direction','SkPath& SkPath::addRect(const SkRect &rect','SkPath& SkPath::addOval(const SkRect &oval','SkPath& SkPath::addRRect(const SkRRect& rrect','SkPath& SkPath::addRRect(const SkRRect &rrect']:
 rrect_shim+=function(skpath_source,prefix)
rrect_cases=[]
for bounds in [[0,0,100,40],[-7,13,33,53],[100,40,0,0],[0,0,0,40]]:
 for radii in [[0,0],[-1,4],[4,0],[4,6],[20,20],[50,20],[300,400]]:
  for clockwise in [False,True]:
   for start in [None,0,1,2,3,4,5,6,7]:
    rrect_cases.append({'bounds':bounds,'radii':radii,'clockwise':clockwise,'start':start})
rrect_main='int main() {\n'
for case in rrect_cases:
 bounds=','.join(str(float(v))+'f' for v in case['bounds'])
 rrect_main+='{SkRRect r;r.setRectXY({'+bounds+'},'+str(float(case['radii'][0]))+'f,'+str(float(case['radii'][1]))+'f);SkPath p;'
 direction='SkPathDirection::kCW' if case['clockwise'] else 'SkPathDirection::kCCW'
 start='' if case['start'] is None else ','+str(case['start'])
 rrect_main+='p.addRRect(r,'+direction+start+');printf("%zu %zu %zu\\n",p.verbs.size(),p.points.size(),p.weights.size()-1);'
 rrect_main+='for(auto v:p.verbs)printf("%u ",v);printf("\\n");for(auto v:p.points)printf("%.9g %.9g\\n",v.fX,v.fY);'
 rrect_main+='for(size_t i=1;i<p.weights.size();++i)printf("%.9g ",p.weights[i]);printf("\\n");}\n'
rrect_main+='}\n'
with tempfile.TemporaryDirectory(prefix='zt-shadow-rrect-path-reference-') as temp:
 root=Path(temp);(root/'reference.cpp').write_text(rrect_shim+rrect_main)
 subprocess.run(['clang++','-std=c++17','-O0','-ffp-contract=off',str(root/'reference.cpp'),'-o',str(root/'reference')],check=True)
 lines=iter(subprocess.check_output([str(root/'reference')],text=True).splitlines())
for case in rrect_cases:
 verb_count,point_count,weight_count=map(int,next(lines).split())
 verbs=list(map(int,next(lines).split()))
 points=[list(map(float,next(lines).split())) for _ in range(point_count)]
 weights=list(map(float,next(lines).split()))
 assert len(verbs)==verb_count and len(weights)==weight_count
 case.update(verbs=verbs,points=points,weights=weights)
rrect_output=output.with_name('android15-shadow-rrect-paths.json')
rrect_output.write_text(json.dumps({'cases':rrect_cases},indent=2,allow_nan=False)+'\n')
print(f'{len(rrect_cases)} pinned rounded rectangle paths: {rrect_output}')

# Integrated convex geometry. Use the original path, projection, inset and mesh
# functions in one executable; only the constructor plumbing is a small adapter.
whole_shim=rrect_shim.replace(' bool operator!=(SkPoint p)',r'''
 SkPoint operator+(SkPoint p) const {return {fX+p.fX,fY+p.fY};}
 SkPoint operator-() const {return {-fX,-fY};}
 SkPoint operator*(float s) const {return {fX*s,fY*s};}
 float dot(SkPoint p) const {return fX*p.fX+fY*p.fY;}
 bool setLength(float);
 bool normalize() {return setLength(1);}
 bool operator!=(SkPoint p)
''')
whole_shim=whole_shim.replace(' void reserve(int n) {data.reserve(n);}',r'''
 void reset() {data.clear();}
 const T& operator[](int n) const {return data[n];}
 T* append() {data.emplace_back();return &data.back();}
 T* append(int n) {auto old=data.size();data.resize(old+n);return data.data()+old;}
 void reserve(int n) {data.reserve(n);}
''')
whole_shim=whole_shim.replace(' float fLeft,fTop,fRight,fBottom;', ' float fLeft,fTop,fRight,fBottom;\n void setBounds(const SkPoint*,int) {}')
whole_shim+=r'''
bool SkIsFinite(float x) {return std::isfinite(x);}
constexpr float SK_ScalarMax=std::numeric_limits<float>::max(),SK_ScalarMin=-SK_ScalarMax;
float SkScalarAbs(float x) {return std::abs(x);}
bool SkScalarNearlyZero(float x,float tolerance) {return std::abs(x)<=tolerance;}
float SkScalarATan2(float y,float x) {return std::atan2(y,x);}
float SkScalarSin(float x) {return std::sin(x);}
float SkScalarCos(float x) {return std::cos(x);}
int SkScalarRoundToInt(float x) {return int(std::floor(double(x)+0.5));}
template<int N,class T> struct AutoSTMalloc {
 std::vector<T> data;AutoSTMalloc(int n):data(n) {}
 T& operator[](int i) {return data[i];}
};
using SkPMColor=uint32_t;
using SkColor=uint32_t;
constexpr SkColor kUmbraColor=0xff000000,kPenumbraColor=0;
'''
whole_shim+=function(point_source,'template <bool use_rsqrt> bool set_point_length')
whole_shim+='bool SkPoint::setLength(float length) {return set_point_length<false>(this,fX,fY,length);}\n'
whole_shim+='namespace SkPointPriv {\n'+function(priv_source,'static bool CanNormalize')+function(priv_source,'static bool EqualsWithinTolerance(const SkPoint& pt, const SkPoint& p, SkScalar tol)')+'}\n'
whole_shim+=poly_source[poly_source.index('struct OffsetSegment'):poly_source.index('// Compute difference vector')]
for prefix in ['static inline bool outside_interval','static inline bool zero_length','static bool compute_intersection','bool SkIsConvexPolygon']:
 whole_shim+=function(poly_source,prefix)
whole_shim+=poly_source[poly_source.index('struct OffsetEdge {'):poly_source.index('static void remove_node')]
for prefix in ['static void remove_node','bool SkInsetConvexPolygon','bool SkComputeRadialSteps']:
 whole_shim+=function(poly_source,prefix)
whole_shim+=color_bodies+'SkPMColor SkPMLerp(SkPMColor a,SkPMColor b,unsigned s) {return SkFastFourByteInterp256_64(a,b,s);}\n'
whole_shim+=function(mesh_shim,'class SkBaseShadowTessellator').replace('SkBaseShadowTessellator','SkNativeShadowMesh')+';\n'
whole_shim+=function(tess,'static bool compute_normal')
for prefix in ['bool SkBaseShadowTessellator::computeConvexShadow', 'void SkBaseShadowTessellator::computeClipVectorsAndTestCentroid',
 'void SkBaseShadowTessellator::addEdge','bool SkBaseShadowTessellator::clipUmbraPoint','bool SkBaseShadowTessellator::addInnerPoint',
 'int SkBaseShadowTessellator::getClosestUmbraIndex','bool SkBaseShadowTessellator::addArc','void SkBaseShadowTessellator::appendTriangle']:
 whole_shim+=function(tess,prefix).replace('SkBaseShadowTessellator::','SkNativeShadowMesh::')
whole_shim+=r'''
void emitMesh(bool prepared,SkBaseShadowTessellator& path,const SkTDArray<SkPoint>* clip,
              float inset,float outset,bool transparent) {
 SkNativeShadowMesh mesh;
 bool valid=prepared;
 if(valid && path.fPathPolygon.size()>=3 && std::isfinite(path.fArea) && (!clip || clip->size()>=3)) {
  mesh.fPathPolygon=path.fPathPolygon;mesh.fCentroid=path.fCentroid;
  mesh.fDirection=path.fDirection;mesh.fTransparent=transparent;
  if(clip)mesh.fClipPolygon=*clip;
  valid=path.fIsConvex && mesh.computeConvexShadow(inset,outset,clip!=nullptr);
 }
 printf("%d %d %d\n",valid,valid?mesh.fPositions.size():0,valid?mesh.fIndices.size():0);
 if(valid) {
  for(int i=0;i<mesh.fPositions.size();++i)printf("%.9g %.9g %u\n",mesh.fPositions[i].fX,mesh.fPositions[i].fY,mesh.fColors[i]>>24);
  for(auto i:mesh.fIndices.data)printf("%u ",i);
 }
 printf("\n");
}
void integrated(const SkRect& bounds,SkPoint radii,const SkMatrix& ctm,SkPoint3 plane,
                SkPoint3 light,float lightRadius,bool transparent) {
 SkRRect r;r.setRectXY(bounds,radii.fX,radii.fY);
 SkPath path;path.addRRect(r,SkPathDirection::kCW);
 auto b=r.getBounds();
 auto heightFunc=[plane](float x,float y){return plane.fX*x+plane.fY*y+plane.fZ;};
 auto baseZ=heightFunc(b.centerX(),b.centerY());
 auto outset=SkDrawShadowMetrics::AmbientBlurRadius(baseZ);
 auto inset=outset*SkDrawShadowMetrics::AmbientRecipAlpha(baseZ)-outset;
 SkAmbientShadowTessellator ambient;
 bool valid=ambient.computePathPolygon(path,ctm);
 emitMesh(valid,ambient,nullptr,inset,outset,transparent);
 SkMatrix projection;float spotOutset=0;
 bool projected=light.fZ>=SK_ScalarNearlyZero && lightRadius>=SK_ScalarNearlyZero &&
  SkDrawShadowMetrics::GetSpotShadowTransform(light,lightRadius,ctm,plane,b,false,&projection,&spotOutset);
 SkSpotShadowTessellator spot;
 valid=projected && spot.computeClipAndPathPolygons(path,ctm,projection);
 emitMesh(valid,spot,&spot.fClipPolygon,spotOutset,spotOutset,transparent);
}
'''
whole_cases=[]
for bounds,radii in [([0,0,100,40],[0,0]),([0,0,100,40],[4,4]),([0,0,100,40],[22,22]),([0,0,40,40],[20,20]),([0,0,100,40],[50,20])]:
 for matrix in [assembly_matrices[i] for i in [0,2,3,4]]:
  for plane in [[0,0,0.1],[0,0,6],[0.1,-0.2,10]]:
   for transparent in [False,True]:
    whole_cases.append({'bounds':bounds,'radii':radii,'matrix':matrix,'plane':plane,'light':[201,-50,500],'lightRadius':800,'transparent':transparent})
for bounds,matrix,plane,light in [([0,0,100,40],assembly_matrices[4],[0,0,500],[201,-50,500]),
 ([0,0,0,40],assembly_matrices[0],[0,0,6],[201,-50,500]),
 ([0,0,100,40],assembly_matrices[0],[0,0,6],[201,-50,0])]:
 whole_cases.append({'bounds':bounds,'radii':[4,4],'matrix':matrix,'plane':plane,'light':light,'lightRadius':800,'transparent':False})
whole_main='int main() {\n'
for case in whole_cases:
 def args(key):return '{'+','.join(str(float(v))+'f' for v in case[key])+'}'
 whole_main+='integrated('+args('bounds')+','+args('radii')+',{'+args('matrix')+'},'+args('plane')+','+args('light')+','+str(float(case['lightRadius']))+'f,'+str(int(case['transparent']))+');\n'
whole_main+='}\n'
with tempfile.TemporaryDirectory(prefix='zt-shadow-integrated-reference-') as temp:
 root=Path(temp);(root/'reference.cpp').write_text(whole_shim+whole_main)
 subprocess.run(['clang++','-std=c++17','-O0','-ffp-contract=off',str(root/'reference.cpp'),'-o',str(root/'reference')],check=True)
 lines=iter(subprocess.check_output([str(root/'reference')],text=True).splitlines())
for case in whole_cases:
 for component in ['ambient','spot']:
  valid,count,index_count=map(int,next(lines).split())
  vertices=[list(map(float,next(lines).split())) for _ in range(count)]
  indices=list(map(int,next(lines).split()))
  assert len(indices)==index_count
  case[component]={'valid':bool(valid),'vertices':vertices,'indices':indices}
whole_output=output.with_name('android15-shadow-integrated.json')
whole_output.write_text(json.dumps({'cases':whole_cases},indent=2,allow_nan=False)+'\n')
print(f'{len(whole_cases)} pinned integrated shadow pairs: {whole_output}')

# Analytic eligibility and inverse precision from the original SkMatrix bodies.
inverse_shim=projection_shim.replace(' using TypeMask=unsigned;',r'''
 using TypeMask=unsigned;
 unsigned fTypeMask=0;
 enum {kRectStaysRect_Mask=64};
 bool isFinite() const {for(float v:fMat)if(!std::isfinite(v))return false;return true;}
 SkMatrix& setTranslate(float x,float y) {return setScaleTranslate(1,1,x,y);}
 bool isSimilarity(float) const;
 bool invertNonIdentity(SkMatrix*) const;
 static void ComputeInv(float[9],const float[9],double,bool);
''')
# The added bookkeeping field makes brace aggregate initialization ambiguous;
# the runner fills fMat directly, like set9.
inverse_shim+=r'''
#define SkDoubleToScalar sk_double_to_float
#undef SkIsFinite
bool SkIsFinite(float x,float y) {return std::isfinite(x)&&std::isfinite(y);}
bool SkScalarNearlyZero(float x,float tolerance) {return std::abs(x)<=tolerance;}
bool SkScalarNearlyEqual(float x,float y,float tolerance=SK_ScalarNearlyZero) {return std::abs(x-y)<=tolerance;}
float SkScalarAbs(float x) {return std::abs(x);}
'''
for prefix in ['static inline SkScalar scross(', 'static inline SkScalar scross_dscale','static inline double dcross(',
 'static inline SkScalar dcross_dscale','static double sk_determinant','static double sk_inv_determinant',
 'static inline bool is_degenerate_2x2','bool SkMatrix::isSimilarity','void SkMatrix::ComputeInv','bool SkMatrix::invertNonIdentity']:
 inverse_shim+=function(matrix_source,prefix)
inverse_cases=list(assembly_matrices)
for x in [-2,-1,0,1/8192,1/4096,1/2048,1,2]:
 for delta in [-1/2048,-1/4096,-1/8192,0,1/8192,1/4096,1/2048]:
  for exchanged in [False,True]:
   for reflection in [False,True]:
    y=(x+delta)*(-1 if reflection else 1)
    inverse_cases.append([0,x,17.125,y,0,-29.75,0,0,1] if exchanged else [x,0,17.125,0,y,-29.75,0,0,1])
inverse_cases += [[1,1e-8,0,0,1,0,0,0,1],[1e-4,1e-4,0,1e-4,1.001e-4,0,0,0,1],
 [1,2,3,2,4,6,0,0,1],[1,0,0,0,1,0,0,0,0],[2e30,0,1,0,3e30,2,0,0,1]]
inverse_main='int main() {\n'
for matrix in inverse_cases:
 values=','.join(str(float(v))+'f' for v in matrix)
 inverse_main+='{SkMatrix m,out;float input[9]={'+values+'};memcpy(m.fMat,input,sizeof(input));'
 inverse_main+='bool axis=!m.hasPerspective() && ((m.fMat[1]==0 && m.fMat[3]==0 && m.fMat[0]!=0 && m.fMat[4]!=0)||(m.fMat[0]==0 && m.fMat[4]==0 && m.fMat[1]!=0 && m.fMat[3]!=0));'
 inverse_main+='bool eligible=axis && m.isSimilarity(SK_ScalarNearlyZero);bool valid;'
 inverse_main+='if(m.isIdentity()){out=m;valid=true;}else{valid=m.invertNonIdentity(&out);}printf("%d %d ",eligible,valid);if(valid)for(float v:out.fMat)printf("%.9g ",v);printf("\\n");}\n'
inverse_main+='}\n'
with tempfile.TemporaryDirectory(prefix='zt-shadow-inverse-reference-') as temp:
 root=Path(temp);(root/'reference.cpp').write_text(inverse_shim+inverse_main)
 subprocess.run(['clang++','-std=c++17','-O0','-ffp-contract=off',str(root/'reference.cpp'),'-o',str(root/'reference')],check=True)
 lines=subprocess.check_output([str(root/'reference')],text=True).splitlines()
inverse_rows=[]
for matrix,line in zip(inverse_cases,lines):
 eligible,valid,*inverse=map(float,line.split())
 inverse_rows.append({'matrix':matrix,'eligible':bool(eligible),'valid':bool(valid),'inverse':inverse})
assert len(lines)==len(inverse_cases)
inverse_output=output.with_name('android15-shadow-inverses.json')
inverse_output.write_text(json.dumps({'cases':inverse_rows},indent=2,allow_nan=False)+'\n')
print(f'{len(inverse_rows)} pinned eligibility/inverse cases: {inverse_output}')

# Full fast geometry: extract the ambient/spot arithmetic from drawFastShadow,
# retaining original SkRRect normalization, transform and inverse bodies. GPU
# allocation/color handling are replaced by emitting ShadowRRectOp::Make inputs.
fast_source=pinned('src/gpu/ganesh/SurfaceDrawContext.cpp','f8b319b537800f70f5bb8e091a696facbdbccc80d37fa50c39954e5035bbd11b')
scale_sides=pinned('src/core/SkScaleToSides.h','a0d230deb15de2876c6292c0913b5d71c8ef7c19b57f501583f25bd69d15852b')
fast_shim=rrect_shim.replace(' using TypeMask=unsigned;',r'''
 using TypeMask=unsigned;
 unsigned fTypeMask=0;
 enum {kRectStaysRect_Mask=64};
 bool isFinite() const {for(float v:fMat)if(!std::isfinite(v))return false;return true;}
 SkMatrix& setTranslate(float x,float y) {return setScaleTranslate(1,1,x,y);}
 bool isSimilarity(float) const;
 bool invertNonIdentity(SkMatrix*) const;
 bool invert(SkMatrix* out) const {if(isIdentity()){*out=*this;return true;}return invertNonIdentity(out);}
 static void ComputeInv(float[9],const float[9],double,bool);
 bool preservesAxisAlignment() const {return !hasPerspective() && ((fMat[1]==0 && fMat[3]==0)||(fMat[0]==0 && fMat[4]==0));}
 bool isScaleTranslate() const {return !(getType()&(kAffine_Mask|kPerspective_Mask));}
 float getScaleX() const {return fMat[0];} float getScaleY() const {return fMat[4];}
 float getSkewX() const {return fMat[1];} float getSkewY() const {return fMat[3];}
 float operator[](int i) const {return fMat[i];}
 bool mapRect(SkRect*,const SkRect&) const;
''')
fast_shim=fast_shim.replace(' bool isEmpty() const {return fLeft',r'''
 bool isSorted() const {return fLeft<=fRight && fTop<=fBottom;}
 SkRect makeOutset(float x,float y) const {return {fLeft-x,fTop-y,fRight+x,fBottom+y};}
 bool isEmpty() const {return fLeft''')
fast_shim=fast_shim.replace('kSimple_Type,kOval_Type','kSimple_Type,kOval_Type,kNinePatch_Type,kComplex_Type')
fast_shim=fast_shim.replace(' bool initializeRect(const SkRect&);',r'''
 void setOval(const SkRect&);
 bool transform(const SkMatrix&,SkRRect*) const;
 bool scaleRadii();void computeType();
 static bool AreRectAndRadiiValid(const SkRect&,const SkVector[4]);
 static SkRRect MakeOval(const SkRect& r) {SkRRect v;v.setOval(r);return v;}
 static SkRRect MakeRectXY(const SkRect& r,float x,float y) {SkRRect v;v.setRectXY(r,x,y);return v;}
 const SkRect& rect() const {return fRect;}
 SkPoint getSimpleRadii() const {return fRadii[0];}
 float width() const {return fRect.width();}
 bool initializeRect(const SkRect&);''')
fast_shim=fast_shim.replace(' bool operator!=(SkPoint p)', ' bool operator==(SkPoint p) const {return fX==p.fX && fY==p.fY;}\n bool operator!=(SkPoint p)')
fast_shim+=inverse_shim[inverse_shim.index('#define SkDoubleToScalar'):].replace(
 'bool SkIsFinite(float x,float y) {return std::isfinite(x)&&std::isfinite(y);}','')
fast_shim+=r'''
#define SkASSERTF(condition,...) assert(condition)

#undef SkDebugf
#define SkDebugf(...) ((void)0)
float sk_float_rsqrt(float x) {return 1.f/std::sqrt(x);}
template<class T> T SkTAbs(T x) {return std::abs(x);}
bool SkToBool(int x) {return x!=0;}
struct SkRectPriv {
 static float HalfWidth(const SkRect& r) {return float(0.5*(double(r.fRight)-double(r.fLeft)));}
 static float HalfHeight(const SkRect& r) {return float(0.5*(double(r.fBottom)-double(r.fTop)));}
};
struct SkRRectPriv {static SkPoint GetSimpleRadii(const SkRRect& r) {return r.getSimpleRadii();}};
bool SkMatrix::mapRect(SkRect* out,const SkRect& r) const {
 SkPoint p[4];mapRectToQuad(p,r);
 *out={p[0].fX,p[0].fY,p[0].fX,p[0].fY};
 for(auto v:p){out->fLeft=std::min(out->fLeft,v.fX);out->fTop=std::min(out->fTop,v.fY);out->fRight=std::max(out->fRight,v.fX);out->fBottom=std::max(out->fBottom,v.fY);}
 return preservesAxisAlignment();
}
'''
fast_shim+=scale_sides[scale_sides.index('class SkScaleToSides'):scale_sides.rindex('#endif')]
for prefix in ['void SkRRect::setOval','static bool clamp_to_zero','static bool radii_are_nine_patch',
 'static double compute_min_scale','static void flush_to_zero','bool SkRRect::scaleRadii',
 'void SkRRect::computeType','static bool are_radius_check_predicates_valid','bool SkRRect::AreRectAndRadiiValid','bool SkRRect::transform']:
 fast_shim+=function(rrect_source,prefix)
fast_shim+=r'''
struct SkShadowFlags {enum {kTransparentOccluder_ShadowFlag=1};};
struct FastRec {SkPoint3 fZPlaneParams;int fFlags;float fLightRadius;};
void emitFast(const SkMatrix& viewMatrix,const SkRRect& rrect,float blurWidth,float insetWidth) {
'''
make_body=op[op.index('    // Do any matrix crunching before'):op.index('    if (scaledInsetWidth <= 0)',op.index('    // Do any matrix crunching before'))]
fast_shim+=make_body+r'''
 printf("%.9g %.9g %.9g %.9g %.9g %.9g %.9g %d\n",bounds.fLeft,bounds.fTop,bounds.fRight,bounds.fBottom,scaledRadius,blurWidth,scaledInsetWidth,rrect.isOval());
}
void fast(const SkRRect& rrect,const SkMatrix& viewMatrix,SkPoint3 devLightPos,float height,float lightRadius,bool transparentInput) {
 FastRec rec={{0,0,height},transparentInput?1:0,lightRadius};bool directional=false;
'''
fast_body=function(fast_source,'bool SurfaceDrawContext::drawFastShadow')
fast_shim+=fast_body[fast_body.index('    // 1/scale'):fast_body.index('    if (SkColorGetA(rec.fAmbientColor)')]
a=fast_body.index('        SkScalar devSpaceInsetWidth');b=fast_body.index('        // The ShadowRRectOp still uses',a)
transparent_start=fast_body.index('        if (transparent)', b)
transparent_end=fast_body.index('        GrOp::Owner op',transparent_start)
fast_shim+='{\n'+fast_body[a:b]+fast_body[transparent_start:transparent_end]+'emitFast(viewMatrix,ambientRRect,devSpaceAmbientBlur,devSpaceInsetWidth);}\n'
a=fast_body.index('        SkScalar devSpaceSpotBlur');b=fast_body.index('        // The ShadowRRectOp still uses',a)
fast_shim+='{\n'+fast_body[a:b]+'emitFast(viewMatrix,spotShadowRRect,2.f*devSpaceSpotBlur,insetWidth);}\n}\n'
fast_cases=[]
fast_matrices=[[1,0,0,0,1,0,0,0,1]]
for sx,sy in [(1,1+1/8192),(1.25,1.25),(2,2-1/4096),(0.25,0.25+1/8192)]:
 for exchange in [False,True]:
  for reflection in [False,True]:
   sx0=-sx if reflection else sx
   fast_matrices.append([0,sx0,173.125,sy,0,-91.75,0,0,1] if exchange else [sx0,0,173.125,0,sy,-91.75,0,0,1])
for bounds,radius in [([0,0,100,40],0),([0,0,100,40],12),([0,0,100,40],20),
 ([-7,13,33,53],20),([0.125,0.375,40.125,40.375],20),([8000.25,4000.5,8040.25,4040.5],19.999998)]:
 for matrix in fast_matrices:
  for height in [1,6,64,499.999969482421875,500,500.000030517578125]:
   for transparent in [False,True]:
    fast_cases.append({'bounds':bounds,'radius':radius,'matrix':matrix,'height':height,'light':[201,-50,500],'lightRadius':800,'transparent':transparent})
fast_main='int main() {\n'
for case in fast_cases:
 vals=lambda x:','.join(str(float(v))+'f' for v in x)
 fast_main+='{SkRRect r;r.setRectXY({'+vals(case['bounds'])+'},'+str(float(case['radius']))+'f,'+str(float(case['radius']))+'f);'
 fast_main+='SkMatrix m;float input[9]={'+vals(case['matrix'])+'};memcpy(m.fMat,input,sizeof(input));'
 fast_main+='fast(r,m,{'+vals(case['light'])+'},'+str(float(case['height']))+'f,800.f,'+str(case['transparent']).lower()+');}\n'
fast_main+='}\n'
with tempfile.TemporaryDirectory(prefix='zt-shadow-fast-reference-') as temp:
 root=Path(temp);(root/'reference.cpp').write_text(fast_shim+fast_main)
 subprocess.run(['clang++','-std=c++17','-O0','-ffp-contract=off',str(root/'reference.cpp'),'-o',str(root/'reference')],check=True)
 lines=iter(subprocess.check_output([str(root/'reference')],text=True).splitlines())
for case in fast_cases:
 for component in ['ambient','spot']:
  values=list(map(float,next(lines).split()))
  case[component]={'bounds':values[:4],'radius':values[4],'blur':values[5],'inset':values[6],'circle':bool(values[7])}
assert next(lines,None) is None
fast_output=output.with_name('android15-shadow-fast.json')
fast_output.write_text(json.dumps({'cases':fast_cases},indent=2,allow_nan=False)+'\n')
print(f'{len(fast_cases)} pinned fast shadow pairs: {fast_output}')

# Blur fallback recipe, including SkPaint's negative-width behavior. Rasterizing
# these recipes is deliberately a separate validation task from their parameters.
shadow_utils=pinned('src/utils/SkShadowUtils.cpp','58d7691fce89d9bf0753221be45a329e2186c263d913b4b103b8c097f99421cd')
blur_mask=pinned('src/core/SkBlurMask.cpp','1dda22d9d52708e954967a4d8eafd58cf8525736052ff6b0d9229c90def889dd')
paint_source=pinned('src/core/SkPaint.cpp','c432559a448e74033cf5381b3816ea11618c985e95368243d4fede80b04d9413')
fallback_shim=shim+body+'}\n'+r'''
struct SkBlurMask {static SkScalar ConvertRadiusToSigma(SkScalar);};
struct SkPaint {float fWidth=0;void setStrokeWidth(SkScalar);};
'''
fallback_shim+=blur_mask[blur_mask.index('static const SkScalar kBLUR_SIGMA_SCALE'):blur_mask.index('SkScalar SkBlurMask::ConvertSigmaToRadius')]
fallback_shim+=function(paint_source,'void SkPaint::setStrokeWidth')
a=shadow_utils.index('            SkScalar devSpaceOutset = SkDrawShadowMetrics::AmbientBlurRadius(zPlaneParams.fZ);')
b=shadow_utils.index('            // Now draw with blur',a)
fallback_shim+='void emitFallback(float height,float spotRadius) {struct {float fZ;} zPlaneParams={height};\n'+shadow_utils[a:b]
fallback_shim+='SkPaint paint;paint.setStrokeWidth(strokeWidth);printf("%.9g %.9g %.9g\\n",paint.fWidth,SkBlurMask::ConvertRadiusToSigma(blurRadius),SkBlurMask::ConvertRadiusToSigma(spotRadius));}\n'
fallback_cases=[{'height':h,'spotRadius':r} for h in [-1,0,1,6,64,128,129,256,300,500,1000] for r in [0,0.125,1,10,100]]
fallback_main='int main(){\n'+''.join('emitFallback('+str(float(c['height']))+'f,'+str(float(c['spotRadius']))+'f);\n' for c in fallback_cases)+'}\n'
with tempfile.TemporaryDirectory(prefix='zt-shadow-fallback-reference-') as temp:
 root=Path(temp);(root/'reference.cpp').write_text(fallback_shim+fallback_main)
 subprocess.run(['clang++','-std=c++17','-O0','-ffp-contract=off',str(root/'reference.cpp'),'-o',str(root/'reference')],check=True)
 lines=subprocess.check_output([str(root/'reference')],text=True).splitlines()
assert len(lines)==len(fallback_cases)
for case,line in zip(fallback_cases,lines):
 stroke,ambient_sigma,spot_sigma=map(float,line.split())
 case.update(stroke=stroke,ambientSigma=ambient_sigma,spotSigma=spot_sigma)
fallback_output=output.with_name('android15-shadow-fallback.json')
fallback_output.write_text(json.dumps({'cases':fallback_cases},indent=2,allow_nan=False)+'\n')
print(f'{len(fallback_cases)} pinned blur fallback recipes: {fallback_output}')

# Shader blur kernels: original Compute2DBlurKernel and bilinear packing bodies.
blur_engine=pinned('src/core/SkBlurEngine.cpp','16c64f15c3595fa6bbe4f9fd2a7d6476758be38e143aadccad509c32bf94f707')
blur_kernel_shim=r'''
#include <algorithm>
#include <array>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <cassert>
#include <cstdint>
#define SkASSERT assert
bool SkScalarNearlyZero(float x) {return std::abs(x)<=1.f/4096;}
template<class T,class U> T SkTo(U x) {return T(x);}
int64_t sk_64_mul(int x,int y) {return int64_t(x)*y;}
struct SkSize {float x,y;float width() const{return x;}float height() const{return y;}};
struct SkISize {int x,y;int width() const{return x;}int height() const{return y;}};
struct SkV4 {float x,y,z,w;};
template<class T> struct SkSpan {T* p;size_t n;SkSpan(T* a,size_t b):p(a),n(b){};SkSpan(T* a,int b):p(a),n(size_t(b)){};size_t size() const{return n;}T* data(){return p;}T& operator[](size_t i){return p[i];}};
struct SkBlurEngine {static int SigmaToRadius(float s){return s<=0.03f?0:int(std::ceil(3.f*s));}};
struct SkShaderBlurAlgorithm {
 static constexpr int kMaxSamples=28;
 static constexpr float kMaxLinearSigma=4.f;
 static constexpr int KernelWidth(int r){return 2*r+1;}
 static constexpr int LinearKernelWidth(int r){return r+1;}
 static void Compute2DBlurKernel(SkSize,SkISize,SkSpan<float>);
 static void Compute1DBlurKernel(float s,int r,SkSpan<float> k){Compute2DBlurKernel({s,0},{r,0},k);}
 static void Compute1DBlurLinearKernel(float,int,std::array<SkV4,kMaxSamples/2>&);
};
'''
blur_kernel_shim+=function(blur_engine,'void SkShaderBlurAlgorithm::Compute2DBlurKernel(SkSize sigma,')
blur_kernel_shim+=function(blur_engine,'void SkShaderBlurAlgorithm::Compute1DBlurLinearKernel(')
blur_sigmas=[0,0.03,0.030000001192092896,0.125,0.3333333432674408,0.3333333730697632,0.5,1,1.25,2,3,4]
blur_kernel_main='int main(){\n'
for s in blur_sigmas:
 blur_kernel_main+='{float s='+str(float(s))+'f;int r=SkBlurEngine::SigmaToRadius(s);std::array<SkV4,14> k;SkShaderBlurAlgorithm::Compute1DBlurLinearKernel(s,r,k);printf("%d ",r);for(auto v:k)printf("%.9g %.9g %.9g %.9g ",v.x,v.y,v.z,v.w);printf("\\n");}\n'
blur_kernel_cases=[]
for sx in blur_sigmas:
 for sy in blur_sigmas:
  # Native runner remains authoritative for the radius; this only bounds storage.
  rx=0 if sx<=0.03 else math.ceil(3*sx)
  ry=0 if sy<=0.03 else math.ceil(3*sy)
  if (2*rx+1)*(2*ry+1)>28:continue
  blur_kernel_cases.append([sx,sy])
  blur_kernel_main+='{SkSize s={'+str(float(sx))+'f,'+str(float(sy))+'f};SkISize r={SkBlurEngine::SigmaToRadius(s.x),SkBlurEngine::SigmaToRadius(s.y)};int n=(2*r.x+1)*(2*r.y+1);float k[28];SkShaderBlurAlgorithm::Compute2DBlurKernel(s,r,{k,28});printf("%d ",n);for(int i=0;i<n;i++)printf("%.9g ",k[i]);printf("\\n");}\n'
blur_kernel_main+='}\n'
with tempfile.TemporaryDirectory(prefix='zt-shadow-blur-kernel-reference-') as temp:
 root=Path(temp);(root/'reference.cpp').write_text(blur_kernel_shim+blur_kernel_main)
 subprocess.run(['clang++','-std=c++17','-O0','-ffp-contract=off',str(root/'reference.cpp'),'-o',str(root/'reference')],check=True)
 lines=iter(subprocess.check_output([str(root/'reference')],text=True).splitlines())
linear_cases=[]
for sigma in blur_sigmas:
 values=list(map(float,next(lines).split()));linear_cases.append({'sigma':sigma,'radius':int(values[0]),'samples':[values[i:i+2] for i in range(1,len(values),2)]})
full_cases=[]
for sigma in blur_kernel_cases:
 values=list(map(float,next(lines).split()));assert int(values[0])==len(values)-1
 full_cases.append({'sigma':sigma,'weights':values[1:]})
assert next(lines,None) is None
blur_kernel_output=output.with_name('android15-shadow-blur-kernel.json')
blur_kernel_output.write_text(json.dumps({'linear':linear_cases,'full':full_cases},indent=2,allow_nan=False)+'\n')
print(f'{len(linear_cases)} linear and {len(full_cases)} full pinned blur kernels: {blur_kernel_output}')

# Large-sigma clamp plans. Compile original sizing/re-expansion and repeated
# linear pass arithmetic, with rectangle/storage adapters only. Both compile-time
# padding branches are represented explicitly; no platform flag is guessed.
blur_utils=pinned('src/gpu/ganesh/GrBlurUtils.cpp','91d4ca8c0e88f95752c436813d780dcd9123ec4a002dce5e3f54f3e530079579')
surface_context=pinned('src/gpu/ganesh/SurfaceContext.cpp','2d0c19fc79e3e1f57eba149c762b9231b24ae9799f1f8b41a9e01ef65b253b40')
rescale_shim=r'''
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <vector>
int sk_float_floor2int(float x){return int(std::floor(x));}
struct SkIPoint {int x,y;SkIPoint operator-()const{return {-x,-y};}};
struct SkISize {int fWidth,fHeight;int width()const{return fWidth;}int height()const{return fHeight;}bool operator!=(SkISize s)const{return fWidth!=s.fWidth || fHeight!=s.fHeight;}};
struct SkIRect {int l,t,r,b;int width()const{return r-l;}int height()const{return b-t;}SkISize size()const{return {width(),height()};}SkIPoint topLeft()const{return {l,t};}SkIRect makeOffset(SkIPoint p)const{return {l+p.x,t+p.y,r+p.x,b+p.y};}int left()const{return l;}int top()const{return t;}void outset(int x,int y){l-=x;t-=y;r+=x;b+=y;}};
struct SkRect {float fLeft,fTop,fRight,fBottom;static SkRect Make(SkIRect r){return {float(r.l),float(r.t),float(r.r),float(r.b)};}void offset(float x,float y){fLeft+=x;fTop+=y;fRight+=x;fBottom+=y;}SkIRect roundOut()const{return {int(std::floor(fLeft)),int(std::floor(fTop)),int(std::ceil(fRight)),int(std::ceil(fBottom))};}};
enum class RescaleMode {kNearest,kLinear,kRepeatedLinear};
void emitRescale(int width,int height,SkIRect dstBounds,float sigmaX,float sigmaY,bool padded) {
 SkIRect srcBounds={0,0,width,height};constexpr float kMaxSigma=4.f;
 int padX=1,padY=1,kDstPadding=padded?1:0;
'''
a=blur_utils.index('    float scaleX = sigmaX > kMaxSigma');b=blur_utils.index('#if !defined(SK_USE_PADDED_BLUR_UPSCALE)',a)
rescale_shim+=blur_utils[a:b]
a=blur_utils.index('    SkRect scaledDstBounds =');b=blur_utils.index('#if defined(SK_USE_PADDED_BLUR_UPSCALE)',a)
rescale_shim+=blur_utils[a:b]
a=blur_utils.index('    auto scaledDstBoundsI =',b);b=blur_utils.index('    SkIRect scaledSrcBounds',a)
rescale_shim+=blur_utils[a:b]
rescale_shim+='scaledDstBounds.offset(-scaledDstBoundsI.left(), -scaledDstBoundsI.top());\n'
rescale_shim+=r'''
 printf("%d %d %.9g %.9g %.9g %.9g %d %d %d %d %.9g %.9g %.9g %.9g\n",rescaledSize.width(),rescaledSize.height(),scaleX,scaleY,sigmaX,sigmaY,scaledDstBoundsI.l,scaledDstBoundsI.t,scaledDstBoundsI.r,scaledDstBoundsI.b,scaledDstBounds.fLeft,scaledDstBounds.fTop,scaledDstBounds.fRight,scaledDstBounds.fBottom);
 SkISize finalSize=rescaledSize;RescaleMode rescaleMode=RescaleMode::kRepeatedLinear;
 auto& srcRect = srcBounds;
 std::vector<SkISize> steps;do {
'''
a=surface_context.index('        SkISize nextDims = finalSize;',surface_context.index('bool SurfaceContext::rescaleInto'))
b=surface_context.index('        auto input =',a)
rescale_shim+=surface_context[a:b]
rescale_shim+='steps.push_back(nextDims);srcBounds={0,0,nextDims.width(),nextDims.height()};}while(srcBounds.size()!=finalSize);printf("%zu ",steps.size());for(auto s:steps)printf("%d %d ",s.width(),s.height());printf("\\n");}\n'
rescale_cases=[]
for size in [[1,1],[2,7],[19,13],[191,97],[1024,513]]:
 for sigma in [[4.000000476837158,0],[8,2],[8,8],[800,1200],[32,0.03],[0,9]]:
  for dst in [[0,0,*size],[-7,3,size[0]+11,size[1]+17]]:
   for padded in [False,True]:rescale_cases.append({'size':size,'sigma':sigma,'destination':dst,'padded':padded})
rescale_main='int main(){\n'
for c in rescale_cases:
 rescale_main+='emitRescale('+','.join(map(str,c['size']))+',{'+','.join(map(str,c['destination']))+'},'+','.join(str(float(x))+'f' for x in c['sigma'])+','+str(c['padded']).lower()+');\n'
rescale_main+='}\n'
with tempfile.TemporaryDirectory(prefix='zt-shadow-rescale-reference-') as temp:
 root=Path(temp);(root/'reference.cpp').write_text(rescale_shim+rescale_main)
 subprocess.run(['clang++','-std=c++17','-O0','-ffp-contract=off',str(root/'reference.cpp'),'-o',str(root/'reference')],check=True)
 lines=iter(subprocess.check_output([str(root/'reference')],text=True).splitlines())
for c in rescale_cases:
 values=list(map(float,next(lines).split()));steps=list(map(int,next(lines).split()))
 assert len(steps)==1+2*steps[0]
 c.update(rescaled=list(map(int,values[:2])),scale=values[2:4],scaledSigma=values[4:6],blurBounds=list(map(int,values[6:10])),reexpandBounds=values[10:14],steps=[steps[i:i+2] for i in range(1,len(steps),2)])
assert next(lines,None) is None
rescale_output=output.with_name('android15-shadow-rescale.json')
rescale_output.write_text(json.dumps({'cases':rescale_cases},indent=2,allow_nan=False)+'\n')
print(f'{len(rescale_cases)} pinned large-sigma clamp plans: {rescale_output}')
