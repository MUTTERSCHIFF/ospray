// ======================================================================== //
// Copyright 2009-2018 Intel Corporation                                    //
//                                                                          //
// Licensed under the Apache License, Version 2.0 (the "License");          //
// you may not use this file except in compliance with the License.         //
// You may obtain a copy of the License at                                  //
//                                                                          //
//     http://www.apache.org/licenses/LICENSE-2.0                           //
//                                                                          //
// Unless required by applicable law or agreed to in writing, software      //
// distributed under the License is distributed on an "AS IS" BASIS,        //
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. //
// See the License for the specific language governing permissions and      //
// limitations under the License.                                           //
// ======================================================================== //

// ospray
#include "TriangleMesh.ih"
#include "common/Model.ih"
#include "math/LinearSpace.ih"
#include "math/sampling.ih"

// embree
#include "embree2/rtcore.isph"
#include "embree2/rtcore_geometry.isph"
#include "embree2/rtcore_geometry_user.isph"



// special 64-bit safe code:
#define BITS 20

#define __define_gather(T)                                                     \
inline T gather_##T(const uniform bool huge,                                   \
                      const T *uniform const base,                             \
                      const varying int index)                                 \
{                                                                              \
  T v;                                                                         \
  if (huge) {                                                                  \
    const int index_lo = index & ((1<<BITS)-1);                                \
    const int index_hi = index - index_lo;                                     \
    foreach_unique(hi in index_hi)                                             \
      v = (base+hi)[index_lo];                                                 \
  } else                                                                       \
    v = base[index];                                                           \
  return v;                                                                    \
}

#define __define_gather_vec3_stride(T, S)                                      \
inline vec3##S gather_vec3##S(const uniform bool huge,                         \
                                const T *uniform const base,                   \
                                const uniform int stride,                      \
                                const varying int index)                       \
{                                                                              \
  vec3##S v;                                                                   \
  if (huge) {                                                                  \
    const int index_lo = index & ((1<<BITS)-1);                                \
    const int index_hi = index - index_lo;                                     \
    /* varying offset of lower bits */                                         \
    const varying int scaledIndexLo = stride * index_lo;                       \
    foreach_unique(hi in index_hi) {                                           \
      /* uniform offset for upper bits */                                      \
      uniform int64 scaledIndexHi = (int64)hi * stride;                        \
      /* properly shifted base address (shifted by 64-bits) */                 \
      const T *uniform base_hi = base + scaledIndexHi;                         \
                                                                               \
      v.x = base_hi[scaledIndexLo+0];                                          \
      v.y = base_hi[scaledIndexLo+1];                                          \
      v.z = base_hi[scaledIndexLo+2];                                          \
    }                                                                          \
  } else {                                                                     \
    const varying int scaledIndex = stride * index;                            \
    v.x = base[scaledIndex+0];                                                 \
    v.y = base[scaledIndex+1];                                                 \
    v.z = base[scaledIndex+2];                                                 \
  }                                                                            \
  return v;                                                                    \
}                                                                              \

__define_gather(vec2f);
__define_gather(vec4f);
__define_gather_vec3_stride(float, f);
__define_gather_vec3_stride(int, i);

static void TriangleMesh_postIntersect(uniform Geometry *uniform _self,
                                       uniform Model    *uniform model,
                                       varying DifferentialGeometry &dg,
                                       const varying Ray &ray,
                                       uniform int64 flags)
{
  TriangleMesh *uniform self = (TriangleMesh *uniform)_self;
  dg.Ng = dg.Ns = ray.Ng;
  const uniform bool huge_mesh = self->huge_mesh;
  const vec3i index = gather_vec3i(huge_mesh, self->index, self->idxSize, ray.primID);
  vec3f bary = make_vec3f(1.0f - ray.u - ray.v, ray.u, ray.v);

  if (flags & DG_NS && self->normal) {
    const uniform float *uniform normal = self->normal;
    const uniform int32 norSize = self->norSize;
    const vec3f a = gather_vec3f(huge_mesh, normal, norSize, index.x);
    const vec3f b = gather_vec3f(huge_mesh, normal, norSize, index.y);
    const vec3f c = gather_vec3f(huge_mesh, normal, norSize, index.z);
    dg.Ns = interpolate(bary, a, b, c);
  }

  if (flags & DG_COLOR && self->color) {
    const uniform vec4f *uniform color = self->color;
    const vec4f a = gather_vec4f(huge_mesh, color, index.x);
    const vec4f b = gather_vec4f(huge_mesh, color, index.y);
    const vec4f c = gather_vec4f(huge_mesh, color, index.z);
    dg.color = interpolate(bary, a, b, c);
    if (!self->has_alpha)
      dg.color.w = 1.f;
  }

  if (flags & DG_TEXCOORD && self->texcoord) {
    const uniform vec2f *uniform texcoord = self->texcoord;
    const vec2f a = gather_vec2f(huge_mesh, texcoord, index.x);
    const vec2f b = gather_vec2f(huge_mesh, texcoord, index.y);
    const vec2f c = gather_vec2f(huge_mesh, texcoord, index.z);
    dg.st = interpolate(bary, a, b, c);
  } else
    dg.st = make_vec2f(0.0f, 0.0f);

  if (flags & DG_TANGENTS) {
    uniform bool fallback = true;
    if (self->texcoord) {
      const uniform vec2f *uniform texcoord = self->texcoord;
      const vec2f a = gather_vec2f(huge_mesh, texcoord, index.x);
      const vec2f b = gather_vec2f(huge_mesh, texcoord, index.y);
      const vec2f c = gather_vec2f(huge_mesh, texcoord, index.z);
      const vec2f dst02 = a - c;
      const vec2f dst12 = b - c;
      const float det = dst02.x * dst12.y - dst02.y * dst12.x;

      if (det != 0.f) {
        const float invDet = rcp(det);
        const uniform float *uniform vertex = self->vertex;
        const uniform int32 vtxSize = self->vtxSize;
        const vec3f a = gather_vec3f(huge_mesh, vertex, vtxSize, index.x);
        const vec3f b = gather_vec3f(huge_mesh, vertex, vtxSize, index.y);
        const vec3f c = gather_vec3f(huge_mesh, vertex, vtxSize, index.z);
        const vec3f dp02 = a - c;
        const vec3f dp12 = b - c;
        dg.dPds = (dst12.y * dp02 - dst02.y * dp12) * invDet;
        dg.dPdt = (dst02.x * dp12 - dst12.x * dp02) * invDet;
        fallback = false;
      }
    }
    if (fallback) {
      linear3f f = frame(dg.Ng);
      dg.dPds = f.vx;
      dg.dPdt = f.vy;
    }
  }

  if (flags & DG_MATERIALID) {
    if (self->prim_materialID) {
      dg.materialID = self->prim_materialID[ray.primID];
    }
    // TODO: gather material ID from index array if indexSize==4
    else {
      dg.materialID = self->geom_materialID;
    }

    if( self->materialList) {
      Material *myMat = self->materialList[dg.materialID < 0 ? 0 : dg.materialID];
      dg.material = myMat;
    }
  }
}

SampleAreaRes TriangleMesh_sampleArea(
    const Geometry *uniform const _self
    , const int32 primID
    , const uniform affine3f &xfm
    , const uniform affine3f &
    , const vec2f& s
    )
{
  const TriangleMesh *const uniform self = (const TriangleMesh *uniform)_self;
  SampleAreaRes res;

  // gather vertices
  const uniform bool huge_mesh = self->huge_mesh;
  const vec3i index = gather_vec3i(huge_mesh, self->index, self->idxSize, primID);
  const uniform float *uniform vertex = self->vertex;
  const uniform int32 vtxSize = self->vtxSize;
  const vec3f a = gather_vec3f(huge_mesh, vertex, vtxSize, index.x);
  const vec3f b = gather_vec3f(huge_mesh, vertex, vtxSize, index.y);
  const vec3f c = gather_vec3f(huge_mesh, vertex, vtxSize, index.z);

  const vec3f localPos = uniformSampleTriangle(a, b, c, s);
  res.pos = xfmPoint(xfm, localPos);

  const vec3f e1 = a-c;
  const vec3f e2 = b-c;
  res.normal = normalize(cross(xfmVector(xfm, e1), xfmVector(xfm, e2)));

  return res;
}

void TriangleMesh_getAreas(
    const Geometry *const uniform _self
    , const uniform affine3f &xfm
    , float *const uniform area
    )
{
  TriangleMesh *uniform self = (TriangleMesh *uniform)_self;

  const uniform int32 tris = self->super.primitives;
  int *uniform index = self->index;
  const uniform int32 idxSize = self->idxSize;
  const float *const uniform vertex = self->vertex;
  const uniform int64 vtxSize = self->vtxSize;
  // TODO vectorize this loop, with foreach or ProgramCount & ProgramIndex
  for(uniform int32 i = 0; i < tris; i++, index += idxSize) {
    const uniform vec3f a = *((vec3f*)(vertex + vtxSize * *index));
    const uniform vec3f b = *((vec3f*)(vertex + vtxSize * *(index+1)));
    const uniform vec3f c = *((vec3f*)(vertex + vtxSize * *(index+2)));
    const uniform vec3f e1 = xfmVector(xfm, a-c);
    const uniform vec3f e2 = xfmVector(xfm, b-c);
    area[i] = 0.5f * length(cross(e1, e2));
  }
}


//! constructor for ispc-side TriangleMesh object
void TriangleMesh_Constructor(uniform TriangleMesh *uniform mesh,
                              void *uniform cppEquivalent,
                              uniform Model *uniform model,
                              uniform int32  geomID,
                              uniform int32  numTriangles,
                              uniform int32  idxSize,
                              uniform int32  vtxSize,
                              uniform int32  norSize,
                              uniform int    *uniform index,
                              uniform float  *uniform vertex,
                              uniform float  *uniform normal,
                              uniform vec4f  *uniform color,
                              uniform vec2f  *uniform texcoord,
                              uniform int32   geom_materialID,
                              uniform Material *uniform material,
                              uniform Material *uniform *uniform materialList,
                              uniform uint32 *uniform prim_materialID,
                              uniform bool has_alpha,
                              uniform bool huge_mesh)
{
  Geometry_Constructor(&mesh->super,cppEquivalent,
                       TriangleMesh_postIntersect,
                       model,geomID,
                       material);
  mesh->super.getAreas = TriangleMesh_getAreas;
  mesh->super.sampleArea = TriangleMesh_sampleArea;
  mesh->super.primitives = numTriangles;
  mesh->index        = index;
  mesh->vertex       = vertex;
  mesh->normal       = normal;
  mesh->color        = color;
  mesh->texcoord     = texcoord;
  mesh->idxSize      = idxSize;
  mesh->vtxSize      = vtxSize;
  mesh->norSize      = norSize;
  mesh->prim_materialID = prim_materialID;
  mesh->materialList = materialList;
  mesh->geom_materialID = geom_materialID;
  mesh->has_alpha = has_alpha;
  mesh->huge_mesh = huge_mesh;
}

export void *uniform TriangleMesh_create(void *uniform cppEquivalent)
{
  TriangleMesh *uniform mesh = uniform new TriangleMesh;
  TriangleMesh_Constructor(mesh, cppEquivalent,
                           NULL, 0, 0, 0, 0, 0, NULL, NULL, NULL, NULL, NULL, -1, NULL, NULL, NULL, true, false);
  return mesh;
}

export void *uniform TriangleMesh_set(void *uniform _mesh,
                                      void *uniform _model,
                                      uniform int32  geomID,
                                      uniform int32  numTriangles,
                                      uniform int32  idxSize,
                                      uniform int32  vtxSize,
                                      uniform int32  norSize,
                                      uniform int    *uniform index,
                                      uniform float  *uniform vertex,
                                      uniform float  *uniform normal,
                                      uniform vec4f  *uniform color,
                                      uniform vec2f  *uniform texcoord,
                                      uniform int32   geom_materialID,
                                      void *uniform material,
                                      void *uniform _materialList,
                                      uniform uint32 *uniform prim_materialID,
                                      uniform bool has_alpha,
                                      uniform bool huge_mesh)
{
  uniform TriangleMesh *uniform mesh = (uniform TriangleMesh *uniform)_mesh;
  uniform Model *uniform model = (uniform Model *uniform)_model;
  uniform Material *uniform *uniform materialList = (uniform Material *uniform *uniform)_materialList;
  TriangleMesh_Constructor(mesh,
                           mesh->super.cppEquivalent,
                           model,
                           geomID,
                           numTriangles,
                           idxSize, vtxSize, norSize,
                           index,
                           vertex,
                           normal,
                           color,
                           texcoord,
                           geom_materialID,
                           (Material*uniform)material,
                           (Material*uniform*uniform)materialList,
                           prim_materialID,
                           has_alpha,
                           huge_mesh);
}
