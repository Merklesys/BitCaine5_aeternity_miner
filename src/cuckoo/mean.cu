/** Cuckoo Cycle, a memory-hard proof-of-work by John Tromp
 * Copyright (c) 2018 Jiri Vadura (photon) and John Tromp
 * Copyright (c) 2018 Miguel Padilla
 *
 * This software is covered by the FAIR MINING license
 */

#include <stdio.h>
#include <string.h>
#include <vector>
#include <assert.h>
#include <chrono>


#ifdef _WIN32
#include "../windows/getopt.h"
#else
#include <unistd.h>
#endif

#include "cuckoo.h"
#include "../crypto/siphash.cuh"
#include "../crypto/blake2.h"

bool will_debug = false;

typedef uint32_t node_t;
typedef uint64_t nonce_t;

typedef std::chrono::milliseconds ms;

#ifndef XBITS
#define XBITS ((EDGEBITS-16)/2)
#endif

#define NODEBITS (EDGEBITS + 1)
#define NNODES ((node_t)1 << NODEBITS)
#define NODEMASK (NNODES - 1)

const static uint32_t NX        = 1 << XBITS;
const static uint32_t NX2       = NX * NX;
const static uint32_t XMASK     = NX - 1;
const static uint32_t X2MASK    = NX2 - 1;
const static uint32_t YBITS     = XBITS;
const static uint32_t NY        = 1 << YBITS;
const static uint32_t YZBITS    = EDGEBITS - XBITS;
const static uint32_t NYZ       = 1 << YZBITS;
const static uint32_t ZBITS     = YZBITS - YBITS;
const static uint32_t NZ        = 1 << ZBITS;

#define EPS_A 133/128
#define EPS_B 85/128

const static uint32_t ROW_EDGES_A = NYZ * EPS_A;
const static uint32_t ROW_EDGES_B = NYZ * EPS_B;

const static uint32_t EDGES_A = ROW_EDGES_A / NX;
const static uint32_t EDGES_B = ROW_EDGES_B / NX;

__constant__ uint2 recoveredges[PROOFSIZE];
__constant__ uint2 e0 = {0,0};

__device__ __forceinline__ uint4 Pack8(const uint32_t e0, const uint32_t e1, const uint32_t e2, const uint32_t e3, const uint32_t e4, const uint32_t e5, const uint32_t e6, const uint32_t e7)
{
  return make_uint4((uint64_t)e0<<32|e1, (uint64_t)e2<<32|e3, (uint64_t)e4<<32|e5, (uint64_t)e6<<32|e7);
}

#ifndef FLUSHA // should perhaps be in trimparams and passed as template parameter
#define FLUSHA 16
#endif

template<int maxOut, typename EdgeOut>
__global__ void SeedA(const siphash_keys &sipkeys, uint4 * __restrict__ buffer, int * __restrict__ indexes)
{
    const int group = blockIdx.x;
    const int dim = blockDim.x;
    const int lid = threadIdx.x;
    const int gid = group * dim + lid;
    const int nthreads = gridDim.x * dim;
    const int FLUSHA2 = 2*FLUSHA;

    __shared__ EdgeOut tmp[NX][FLUSHA2]; // needs to be uint4 aligned
    const int TMPPERLL4 = sizeof(uint4) / sizeof(EdgeOut);
    __shared__ int counters[NX];

    for (int row = lid; row < NX; row += dim)
    {
        counters[row] = 0;
    }
    __syncthreads();

    const int col = group % NX;
    const int loops = NEDGES / nthreads;

    for (int i = 0; i < loops; i++)
    {
      uint32_t nonce = gid * loops + i;
      uint32_t node1, node0 = dipnode(sipkeys, (uint64_t)nonce, 0);

      if (sizeof(EdgeOut) == sizeof(uint2))
      {
          node1 = dipnode(sipkeys, (uint64_t)nonce, 1);
      }

      int row = node0 & XMASK;
      int counter = min((int)atomicAdd(counters + row, 1), (int)(FLUSHA2-1));
      tmp[row][counter] = make_Edge(nonce, tmp[0][0], node0, node1);

      __syncthreads();

      if (counter == FLUSHA-1)
      {
        int localIdx = min(FLUSHA2, counters[row]);
        int newCount = localIdx % FLUSHA;
        int nflush = localIdx - newCount;
        int cnt = min((int)atomicAdd(indexes + row * NX + col, nflush), (int)(maxOut - nflush));

        for (int i = 0; i < nflush; i += TMPPERLL4)
        {
            buffer[((uint64_t)(row * NX + col) * maxOut + cnt + i) / TMPPERLL4] = *(uint4 *)(&tmp[row][i]);
        }

        for (int t = 0; t < newCount; t++)
        {
          tmp[row][t] = tmp[row][t + nflush];
        }

        counters[row] = newCount;
      }
      __syncthreads();
    }

    EdgeOut zero = make_Edge(0, tmp[0][0], 0, 0);

    for (int row = lid; row < NX; row += dim)
    {
      int localIdx = min(FLUSHA2, counters[row]);
      for (int j = localIdx; j % TMPPERLL4; j++)
      {
          tmp[row][j] = zero;
      }
      for (int i = 0; i < localIdx; i += TMPPERLL4)
      {
        int cnt = min((int)atomicAdd(indexes + row * NX + col, TMPPERLL4), (int)(maxOut - TMPPERLL4));
        buffer[((uint64_t)(row * NX + col) * maxOut + cnt) / TMPPERLL4] = *(uint4 *)(&tmp[row][i]);
      }
    }
}

template <typename Edge> __device__ bool null(Edge e);

__device__ bool null(uint32_t nonce) {
  return nonce == 0;
}

__device__ bool null(uint2 nodes) {
  return nodes.x == 0 && nodes.y == 0;
}

#ifndef FLUSHB
#define FLUSHB 8
#endif

template<int maxOut, typename EdgeOut>
__global__ void SeedB(const siphash_keys &sipkeys, const EdgeOut * __restrict__ source, uint4 * __restrict__ destination, const int * __restrict__ sourceIndexes, int * __restrict__ destinationIndexes) {
  const int group = blockIdx.x;
  const int dim = blockDim.x;
  const int lid = threadIdx.x;
  const int FLUSHB2 = 2 * FLUSHB;

  __shared__ EdgeOut tmp[NX][FLUSHB2];
  const int TMPPERLL4 = sizeof(uint4) / sizeof(EdgeOut);
  __shared__ int counters[NX];

  // if (group>=0&&lid==0) fprintf(stderr, "group  %d  -\n", group);
  for (int col = lid; col < NX; col += dim)
    counters[col] = 0;
  __syncthreads();
  const int row = group / NX;
  const int bucketEdges = min((int)sourceIndexes[group], (int)maxOut);
  const int loops = (bucketEdges + dim-1) / dim;
  for (int loop = 0; loop < loops; loop++) {
    int col;
    int counter = 0;
    const int edgeIndex = loop * dim + lid;
    if (edgeIndex < bucketEdges) {
      const int index = group * maxOut + edgeIndex;
      EdgeOut edge = __ldg(&source[index]);
      if (null(edge)) continue;
      uint32_t node1 = endpoint(sipkeys, edge, 0);
      col = (node1 >> XBITS) & XMASK;
      counter = min((int)atomicAdd(counters + col, 1), (int)(FLUSHB2-1));
      tmp[col][counter] = edge;
    }
    __syncthreads();
    if (counter == FLUSHB-1) {
      int localIdx = min(FLUSHB2, counters[col]);
      int newCount = localIdx % FLUSHB;
      int nflush = localIdx - newCount;
      int cnt = min((int)atomicAdd(destinationIndexes + row * NX + col, nflush), (int)(maxOut - nflush));
      for (int i = 0; i < nflush; i += TMPPERLL4)
        destination[((uint64_t)(row * NX + col) * maxOut + cnt + i) / TMPPERLL4] = *(uint4 *)(&tmp[col][i]);
      for (int t = 0; t < newCount; t++) {
        tmp[col][t] = tmp[col][t + nflush];
      }
      counters[col] = newCount;
    }
    __syncthreads(); 
  }
  EdgeOut zero = make_Edge(0, tmp[0][0], 0, 0);
  for (int col = lid; col < NX; col += dim) {
    int localIdx = min(FLUSHB2, counters[col]);
    for (int j = localIdx; j % TMPPERLL4; j++)
      tmp[col][j] = zero;
    for (int i = 0; i < localIdx; i += TMPPERLL4) {
      int cnt = min((int)atomicAdd(destinationIndexes + row * NX + col, TMPPERLL4), (int)(maxOut - TMPPERLL4));
      destination[((uint64_t)(row * NX + col) * maxOut + cnt) / TMPPERLL4] = *(uint4 *)(&tmp[col][i]);
    }
  }
}

__device__ __forceinline__  void Increase2bCounter(uint32_t *ecounters, const int bucket) {
  int word = bucket >> 5;
  unsigned char bit = bucket & 0x1F;
  uint32_t mask = 1 << bit;

  uint32_t old = atomicOr(ecounters + word, mask) & mask;
  if (old)
    atomicOr(ecounters + word + NZ/32, mask);
}

__device__ __forceinline__  bool Read2bCounter(uint32_t *ecounters, const int bucket) {
  int word = bucket >> 5;
  unsigned char bit = bucket & 0x1F;
  uint32_t mask = 1 << bit;

  return (ecounters[word + NZ/32] & mask) != 0;
}

__device__ uint2 make_Edge(const uint32_t nonce, const uint2 dummy, const uint32_t node0, const uint32_t node1) {
   return make_uint2(node0, node1);
}

__device__ uint2 make_Edge(const uint2 edge, const uint2 dummy, const uint32_t node0, const uint32_t node1) {
   return edge;
}

__device__ uint32_t make_Edge(const uint32_t nonce, const uint32_t dummy, const uint32_t node0, const uint32_t node1) {
   return nonce;
}

template <typename Edge> uint32_t __device__ endpoint(const siphash_keys &sipkeys, Edge e, int uorv);

__device__ uint32_t endpoint(const siphash_keys &sipkeys, uint32_t nonce, int uorv) {
  return dipnode(sipkeys, nonce, uorv);
}

__device__ uint32_t endpoint(const siphash_keys &sipkeys, uint2 nodes, int uorv) {
  return uorv ? nodes.y : nodes.x;
}

template<int maxIn, typename EdgeIn, int maxOut, typename EdgeOut>
__global__ void Round(const int round, const siphash_keys &sipkeys, const EdgeIn * __restrict__ source, EdgeOut * __restrict__ destination, const int * __restrict__ sourceIndexes, int * __restrict__ destinationIndexes) {
  const int group = blockIdx.x;
  const int dim = blockDim.x;
  const int lid = threadIdx.x;
  const static int COUNTERWORDS = NZ / 16; // 16 2-bit counters per 32-bit word

  __shared__ uint32_t ecounters[COUNTERWORDS];

  for (int i = lid; i < COUNTERWORDS; i += dim)
    ecounters[i] = 0;
  __syncthreads();
  const int edgesInBucket = min(sourceIndexes[group], maxIn);
  const int loops = (edgesInBucket + dim-1) / dim;

  for (int loop = 0; loop < loops; loop++) {
    const int lindex = loop * dim + lid;
    if (lindex < edgesInBucket) {
      const int index = maxIn * group + lindex;
      EdgeIn edge = __ldg(&source[index]);
      if (null(edge)) continue;
      uint32_t node = endpoint(sipkeys, edge, round&1);
      Increase2bCounter(ecounters, node >> (2*XBITS));
    }
  }
  __syncthreads();
  for (int loop = 0; loop < loops; loop++) {
    const int lindex = loop * dim + lid;
    if (lindex < edgesInBucket) {
      const int index = maxIn * group + lindex;
      EdgeIn edge = __ldg(&source[index]);
      if (null(edge)) continue;
      uint32_t node0 = endpoint(sipkeys, edge, round&1);
      if (Read2bCounter(ecounters, node0 >> (2*XBITS))) {
        uint32_t node1 = endpoint(sipkeys, edge, (round&1)^1);
        const int bucket = node1 & X2MASK;
        const int bktIdx = min(atomicAdd(destinationIndexes + bucket, 1), maxOut - 1);
        destination[bucket * maxOut + bktIdx] = (round&1) ? make_Edge(edge, *destination, node1, node0)
                                                          : make_Edge(edge, *destination, node0, node1);
      }
    }
  }
  // if (group==0&&lid==0) fprintf(stderr, "round %d cnt(0,0) %d\n", round, sourceIndexes[0]);
}

template<int maxIn>
__global__ void Tail(const uint2 *source, uint2 *destination, const int *sourceIndexes, int *destinationIndexes) {
  const int lid = threadIdx.x;
  const int group = blockIdx.x;
  const int dim = blockDim.x;
  int myEdges = sourceIndexes[group];
  __shared__ int destIdx;

  if (lid == 0)
    destIdx = atomicAdd(destinationIndexes, myEdges);
  __syncthreads();
  for (int i = lid; i < myEdges; i += dim)
    destination[destIdx + lid] = source[group * maxIn + lid];
}

#ifdef DEBUG
#define checkCudaErrors(ans) { gpuAssert((ans), __FILE__, __LINE__); }
inline void gpuAssert(cudaError_t code, const char *file, int line, bool abort=true) {
  if (code != cudaSuccess) {
    fprintf(stderr,"GPUassert: %s %s %d\n", cudaGetErrorString(code), file, line);
    if (abort) exit(code);
  }
}
#endif

__global__ void Recovery(const siphash_keys &sipkeys, uint4 *buffer, int *indexes) {
  const int gid = blockDim.x * blockIdx.x + threadIdx.x;
  const int lid = threadIdx.x;
  const int nthreads = blockDim.x * gridDim.x;
  const int loops = NEDGES / nthreads;
  __shared__ uint32_t nonces[PROOFSIZE];
  
  if (lid < PROOFSIZE) nonces[lid] = 0;
  __syncthreads();
  for (int i = 0; i < loops; i++) {
    uint64_t nonce = gid * loops + i;
    uint64_t u = dipnode(sipkeys, nonce, 0);
    uint64_t v = dipnode(sipkeys, nonce, 1);
    for (int i = 0; i < PROOFSIZE; i++) {
      if (recoveredges[i].x == u && recoveredges[i].y == v)
        nonces[i] = nonce;
    }
  }
  __syncthreads();
  if (lid < PROOFSIZE) {
    if (nonces[lid] > 0)
      indexes[lid] = nonces[lid];
  }
}

struct blockstpb {
  uint16_t blocks;
  uint16_t tpb;
};

struct trimparams {
  uint16_t expand;
  uint16_t ntrims;
  blockstpb genA;
  blockstpb genB;
  blockstpb trim;
  blockstpb tail;
  blockstpb recover;

  trimparams() {
    expand              =    0;
    ntrims              =  176;
    genA.blocks         = 4096;
    genA.tpb            =  256;
    genB.blocks         =  NX2;
    genB.tpb            =  128;
    trim.blocks         =  NX2;
    trim.tpb            =  512;
    tail.blocks         =  NX2;
    tail.tpb            = 1024;
    recover.blocks      = 1024;
    recover.tpb         = 1024;
  }
};

typedef uint32_t proof[PROOFSIZE];

// maintains set of trimmable edges
struct edgetrimmer {
  trimparams tp;
  edgetrimmer *dt;
  size_t sizeA, sizeB;
  const size_t indexesSize = NX * NY * sizeof(uint32_t);
  uint4 *bufferA;
  uint4 *bufferB;
  uint4 *bufferAB;
  int *indexesE;
  int *indexesE2;
  uint32_t hostA[NX * NY];
  uint32_t *uvnodes;
  proof sol;
  siphash_keys sipkeys, *dipkeys;

  edgetrimmer(const trimparams _tp)
  {
    tp = _tp;
    cudaMalloc((void**)&dt, sizeof(edgetrimmer));
    cudaMalloc((void**)&uvnodes, PROOFSIZE * 2 * sizeof(uint32_t));
    cudaMalloc((void**)&dipkeys, sizeof(siphash_keys));
    cudaMalloc((void**)&indexesE, indexesSize);
    cudaMalloc((void**)&indexesE2, indexesSize);

    sizeA = ROW_EDGES_A * NX * (tp.expand > 0 ? sizeof(uint32_t) : sizeof(uint2));
    sizeB = ROW_EDGES_B * NX * (tp.expand > 1 ? sizeof(uint32_t) : sizeof(uint2));
    const size_t bufferSize = sizeA + sizeB;

    cudaMalloc((void**)&bufferA, bufferSize);

    bufferB  = bufferA + sizeA / sizeof(uint4);
    bufferAB = bufferA + sizeB / sizeof(uint4);
  }

  uint64_t globalbytes() const
  {
    return (sizeA+sizeB) + 2 * indexesSize + sizeof(siphash_keys) + PROOFSIZE * 2 * sizeof(uint32_t) + sizeof(edgetrimmer);
  }

  ~edgetrimmer()
  {
    cudaFree(bufferA);
    cudaFree(indexesE2);
    cudaFree(indexesE);
    cudaFree(dipkeys);
    cudaFree(uvnodes);
    cudaFree(dt);
    cudaDeviceReset();
  }

  uint32_t trim()
  {
    cudaMemcpy(dt, this, sizeof(edgetrimmer), cudaMemcpyHostToDevice);

    cudaMemset(indexesE, 0, indexesSize);
    cudaMemset(indexesE2, 0, indexesSize);

    cudaMemcpy(dipkeys, &sipkeys, sizeof(sipkeys), cudaMemcpyHostToDevice);
  
    cudaDeviceSynchronize();

    if (tp.expand == 0)
    {
        SeedA<EDGES_A, uint2><<<tp.genA.blocks, tp.genA.tpb>>>(*dipkeys, bufferAB, (int *)indexesE);
    }
    else
    {
        SeedA<EDGES_A, uint32_t><<<tp.genA.blocks, tp.genA.tpb>>>(*dipkeys, bufferAB, (int *)indexesE);
    }
  
    cudaDeviceSynchronize();

    const uint32_t halfA = sizeA/2 / sizeof(uint4);
    const uint32_t halfE = NX2 / 2;

    if (tp.expand == 0)
    {
      SeedB<EDGES_A, uint2><<<tp.genB.blocks/2, tp.genB.tpb>>>(*dipkeys, (const uint2 *)bufferAB, bufferA, (const int *)indexesE, indexesE2);
      SeedB<EDGES_A, uint2><<<tp.genB.blocks/2, tp.genB.tpb>>>(*dipkeys, (const uint2 *)(bufferAB+halfA), bufferA+halfA, (const int *)(indexesE+halfE), indexesE2+halfE);
    }
    else
    {
      SeedB<EDGES_A, uint32_t><<<tp.genB.blocks/2, tp.genB.tpb>>>(*dipkeys, (const   uint32_t *)bufferAB, bufferA, (const int *)indexesE, indexesE2);
      SeedB<EDGES_A, uint32_t><<<tp.genB.blocks/2, tp.genB.tpb>>>(*dipkeys, (const   uint32_t *)(bufferAB+halfA), bufferA+halfA, (const int *)(indexesE+halfE), indexesE2+halfE);
    }

    cudaDeviceSynchronize();

    cudaMemset(indexesE, 0, indexesSize);

    if (tp.expand == 0)
    {
        Round<EDGES_A, uint2, EDGES_B, uint2><<<tp.trim.blocks, tp.trim.tpb>>>(0, *dipkeys, (const uint2 *)bufferA, (uint2 *)bufferB, (const int *)indexesE2, (int *)indexesE); // to .632
    }
    else if (tp.expand == 1)
    {
        Round<EDGES_A,   uint32_t, EDGES_B, uint2><<<tp.trim.blocks, tp.trim.tpb>>>(0, *dipkeys, (const   uint32_t *)bufferA, (uint2 *)bufferB, (const int *)indexesE2, (int *)indexesE); // to .632
    }
    else
    {
        Round<EDGES_A,   uint32_t, EDGES_B,   uint32_t><<<tp.trim.blocks, tp.trim.tpb>>>(0, *dipkeys, (const   uint32_t *)bufferA, (  uint32_t *)bufferB, (const int *)indexesE2, (int *)indexesE); // to .632
    }

    cudaMemset(indexesE2, 0, indexesSize);

    if (tp.expand < 2)
    {
        Round<EDGES_B, uint2, EDGES_B/2, uint2><<<tp.trim.blocks, tp.trim.tpb>>>(1, *dipkeys, (const uint2 *)bufferB, (uint2 *)bufferA, (const int *)indexesE, (int *)indexesE2); // to .296
    }
    else
    {
        Round<EDGES_B,   uint32_t, EDGES_B/2, uint2><<<tp.trim.blocks, tp.trim.tpb>>>(1, *dipkeys, (const   uint32_t *)bufferB, (uint2 *)bufferA, (const int *)indexesE, (int *)indexesE2); // to .296
    }

    cudaMemset(indexesE, 0, indexesSize);
    Round<EDGES_B/2, uint2, EDGES_A/4, uint2><<<tp.trim.blocks, tp.trim.tpb>>>(2, *dipkeys, (const uint2 *)bufferA, (uint2 *)bufferB, (const int *)indexesE2, (int *)indexesE); // to .176
    cudaMemset(indexesE2, 0, indexesSize);
    Round<EDGES_A/4, uint2, EDGES_B/4, uint2><<<tp.trim.blocks, tp.trim.tpb>>>(3, *dipkeys, (const uint2 *)bufferB, (uint2 *)bufferA, (const int *)indexesE, (int *)indexesE2); // to .117
  
    cudaDeviceSynchronize();
  
    for (int round = 4; round < tp.ntrims; round += 2)
    {
      cudaMemset(indexesE, 0, indexesSize);
      Round<EDGES_B/4, uint2, EDGES_B/4, uint2><<<tp.trim.blocks, tp.trim.tpb>>>(round, *dipkeys,  (const uint2 *)bufferA, (uint2 *)bufferB, (const int *)indexesE2, (int *)indexesE);
      cudaMemset(indexesE2, 0, indexesSize);
      Round<EDGES_B/4, uint2, EDGES_B/4, uint2><<<tp.trim.blocks, tp.trim.tpb>>>(round+1, *dipkeys,  (const uint2 *)bufferB, (uint2 *)bufferA, (const int *)indexesE, (int *)indexesE2);
    }
    
    cudaMemset(indexesE, 0, indexesSize);
    cudaDeviceSynchronize();
  
    Tail<EDGES_B/4><<<tp.tail.blocks, tp.tail.tpb>>>((const uint2 *)bufferA, (uint2 *)bufferB, (const int *)indexesE2, (int *)indexesE);
    cudaMemcpy(hostA, indexesE, NX * NY * sizeof(uint32_t), cudaMemcpyDeviceToHost);

    cudaDeviceSynchronize();

    return hostA[0];
  }

};

#define IDXSHIFT 10
#define CUCKOO_SIZE (NNODES >> IDXSHIFT)
#define CUCKOO_MASK (CUCKOO_SIZE - 1)
// number of (least significant) key bits that survives leftshift by NODEBITS
#define KEYBITS (64-NODEBITS)
#define KEYMASK ((1L << KEYBITS) - 1)
#define MAXDRIFT (1L << (KEYBITS - IDXSHIFT))

class cuckoo_hash
{
    public:
        uint64_t *cuckoo;

        cuckoo_hash()
        {
          cuckoo = new uint64_t[CUCKOO_SIZE];
        }

        ~cuckoo_hash()
        {
          delete[] cuckoo;
        }

        void set(node_t u, node_t v)
        {
            uint64_t niew = (uint64_t)u << NODEBITS | v;
            for (node_t ui = u >> IDXSHIFT; ; ui = (ui+1) & CUCKOO_MASK)
            {
                uint64_t old = cuckoo[ui];
                if (old == 0 || (old >> NODEBITS) == (u & KEYMASK))
                {
                    cuckoo[ui] = niew;
                    return;
                }
            }
        }

        node_t operator[](node_t u) const
        {
            for (node_t ui = u >> IDXSHIFT; ; ui = (ui+1) & CUCKOO_MASK)
            {
                uint64_t cu = cuckoo[ui];

                if (!cu)
                {
                    return 0;
                }

                if ((cu >> NODEBITS) == (u & KEYMASK))
                {
                  return (node_t)(cu & NODEMASK);
                }
            }
        }
};

const static uint32_t MAXPATHLEN = 8 << ((NODEBITS+2)/3);

int nonce_cmp(const void *a, const void *b)
{
    return *(uint32_t *)a - *(uint32_t *)b;
}

const static uint32_t MAXEDGES = 0x20000;

struct solver_ctx
{
    edgetrimmer *trimmer;
    uint2 *edges;
    cuckoo_hash *cuckoo;
    uint2 soledges[PROOFSIZE];

    std::vector<uint32_t> sols; // concatenation of all proof's indices

    uint32_t us[MAXPATHLEN];
    uint32_t vs[MAXPATHLEN];

    solver_ctx(const trimparams tp)
    {
        trimmer = new edgetrimmer(tp);
        edges   = new uint2[MAXEDGES];
        cuckoo  = new cuckoo_hash();
    }

    void set_header_nonce(char * const headernonce, const uint32_t len, const uint32_t nonce)
    {
        ((uint32_t *)headernonce)[len/sizeof(uint32_t)-1] = htole32(nonce);
        setheader(headernonce, len, &trimmer->sipkeys);
        sols.clear();
    }

    ~solver_ctx()
    {
      delete cuckoo;
      delete[] edges;
      delete trimmer;
    }

    void recordedge(const uint32_t i, const uint32_t u2, const uint32_t v2)
    {
        soledges[i].x = u2/2;
        soledges[i].y = v2/2;
    }

    void solution(const uint32_t *us, uint32_t nu, const uint32_t *vs, uint32_t nv)
    {
      uint32_t ni = 0;
      recordedge(ni++, *us, *vs);

      while (nu--)
      {
          recordedge(ni++, us[(nu+1)&~1], us[nu|1]); // u's in even position; v's in odd
      }
      while (nv--)
      {
          recordedge(ni++, vs[nv|1], vs[(nv+1)&~1]); // u's in odd position; v's in even
      }

      sols.resize(sols.size() + PROOFSIZE);

      cudaMemcpyToSymbol(recoveredges, soledges, sizeof(soledges));
      cudaMemset(trimmer->indexesE2, 0, trimmer->indexesSize);

      Recovery<<<trimmer->tp.recover.blocks, trimmer->tp.recover.tpb>>>(*trimmer->dipkeys, trimmer->bufferA, (int *)trimmer->indexesE2);

      cudaMemcpy(&sols[sols.size()-PROOFSIZE], trimmer->indexesE2, PROOFSIZE * sizeof(uint32_t), cudaMemcpyDeviceToHost);

      cudaDeviceSynchronize();

      qsort(&sols[sols.size()-PROOFSIZE], PROOFSIZE, sizeof(uint32_t), nonce_cmp);
    }

    uint32_t path(uint32_t u, uint32_t *us)
    {
      uint32_t nu, u0 = u;
      for (nu = 0; u; u = (*cuckoo)[u])
      {
        if (nu >= MAXPATHLEN)
        {
          while (nu-- && us[nu] != u) ;
          if (~nu)
          {
            fprintf(stderr, "illegal %4d-cycle from node %d\n", MAXPATHLEN-nu, u0);
            exit(0);
          }

          fprintf(stderr, "maximum path length exceeded\n");
          return 0; // happens once in a million runs or so; signal trouble
        }

        us[nu++] = u;
      }

      return nu;
    }

    void addedge(uint2 edge)
    {
      const uint32_t u0 = edge.x << 1, v0 = (edge.y << 1) | 1;
      if (u0)
      {
        uint32_t nu = path(u0, us), nv = path(v0, vs);
        if (!nu-- || !nv--)
        {
            return; // drop edge causing trouble
        }

        if (us[nu] == vs[nv])
        {
          const uint32_t min = nu < nv ? nu : nv;
          for (nu -= min, nv -= min; us[nu] != vs[nv]; nu++, nv++) ;

          const uint32_t len = nu + nv + 1;

          if(will_debug)
          {
              fprintf(stderr, "%4d-cycle found\n", len);
          }

          if (len == PROOFSIZE)
          {
             solution(us, nu, vs, nv);
          }

        }
        else if (nu < nv)
        {
          while (nu--)
          {
              cuckoo->set(us[nu+1], us[nu]);
          }
          cuckoo->set(u0, v0);
        }
        else
        {
          while (nv--)
          {
             cuckoo->set(vs[nv+1], vs[nv]);
          }

          cuckoo->set(v0, u0);
        }
      }
    }

    void findcycles(uint2 *edges, uint32_t nedges)
    {
      memset(cuckoo->cuckoo, 0, CUCKOO_SIZE * sizeof(uint64_t));

      for (uint32_t i = 0; i < nedges; i++)
      {
          addedge(edges[i]);
      }

    }

    int solve()
    {
      uint32_t timems,timems2;
      auto time0 = std::chrono::high_resolution_clock::now();
      uint32_t nedges = trimmer->trim();

      if (nedges > MAXEDGES)
      {
        fprintf(stderr, "OOPS; losing %d edges beyond MAXEDGES=%d\n", nedges-MAXEDGES, MAXEDGES);
        nedges = MAXEDGES;
      }

      cudaMemcpy(edges, trimmer->bufferB, nedges * 8, cudaMemcpyDeviceToHost);

      auto time1 = std::chrono::high_resolution_clock::now();
      auto duration = std::chrono::duration_cast<ms>(time1 - time0);

      timems = duration.count();
      time0 = std::chrono::high_resolution_clock::now();
      findcycles(edges, nedges);
      time1 = std::chrono::high_resolution_clock::now();
      duration = std::chrono::duration_cast<ms>(time1 - time0);
      timems2 = duration.count();
      
      if(will_debug)
      {
         fprintf(stderr, "findcycles edges %d time %d ms total %d ms\n", nedges, timems2, timems+timems2);
      }
      
      return sols.size() / PROOFSIZE;
    }

};

// arbitrary length of header hashed into siphash key
#define HEADERLEN 80

int main(int argc, char **argv)
{
    trimparams tp;
    uint32_t nonce = 0;
    uint32_t range = 1;
    uint32_t device = 0;
    char header[HEADERLEN];
    uint32_t len;
    char my_solution[1024];
    int opt;
    bool cpuload = false;

    memset(header, 0, sizeof(header));
    static const char *optString = "scb:c:d:E:h:k:m:n:r:U:u:v:w:y:Z:z:gb:";

    while ((opt = getopt(argc, argv, optString)) != -1)
    {
        switch (opt)
        {
           case 'c':
               cpuload = true;
               break;
           case 's':
               fprintf(stderr, "SYNOPSIS\n  cuda%d [-d device] [-E 0-2] [-h hexheader] [-m trims] [-n nonce] [-r range] [-U seedAblocks] [-u seedAthreads] [-v seedBthreads] [-w Trimthreads] [-y Tailthreads] [-Z recoverblocks] [-z recoverthreads]\n", NODEBITS);
               fprintf(stderr, "DEFAULTS\n  cuda%d -d %d -E %d -h \"\" -m %d -n %d -r %d -U %d -u %d -v %d -w %d -y %d -Z %d -z %d\n", NODEBITS, device, tp.expand, tp.ntrims, nonce, range, tp.genA.blocks, tp.genA.tpb, tp.genB.tpb, tp.trim.tpb, tp.tail.tpb, tp.recover.blocks, tp.recover.tpb);
               exit(0);
           case 'd':
               device = atoi(optarg);
               break;
           case 'E':
               tp.expand = atoi(optarg);
               break;
           case 'g':
                will_debug = true;
                break;
           case 'h':
               len = strlen(optarg)/2;
               for (uint32_t i=0; i<len; i++)
               {
                   sscanf(optarg+2*i, "%2hhx", header+i); // hh specifies storage of a single byte
               }
               break;
           case 'n':
               nonce = atoi(optarg);
               break;
           case 'm':
               tp.ntrims = atoi(optarg) & -2; // make even as required by solve()
               break;
           case 'r':
               range = atoi(optarg);
               break;
           case 'U':
               tp.genA.blocks = atoi(optarg);
               break;
           case 'u':
               tp.genA.tpb = atoi(optarg);
               break;
           case 'v':
               tp.genB.tpb = atoi(optarg);
               break;
           case 'w':
               tp.trim.tpb = atoi(optarg);
               break;
           case 'y':
               tp.tail.tpb = atoi(optarg);
               break;
           case 'Z':
               tp.recover.blocks = atoi(optarg);
               break;
           case 'z':
               tp.recover.tpb = atoi(optarg);
               break;
      }
    }

    int nDevices;
    cudaGetDeviceCount(&nDevices);
    cudaDeviceProp prop;
    cudaGetDeviceProperties(&prop, device);

    cudaSetDevice(device);
    if (cpuload)
    {
        // may be for old and pure systems but not for highspeed machines!!
        cudaSetDeviceFlags(cudaDeviceScheduleBlockingSync);
    }
    else
    {
        // best performance
        cudaSetDeviceFlags(cudaDeviceScheduleYield);
    }

    if (will_debug)
    {
        uint64_t dbytes = prop.totalGlobalMem;
        int dunit;
        for (dunit=0; dbytes >= 10240; dbytes>>=10,dunit++) ;

        fprintf(stderr, "%s with %d%cB @ %d bits x %dMHz\n", prop.name, (uint32_t)dbytes, " KMGT"[dunit], prop.memoryBusWidth, prop.memoryClockRate/1000);

        fprintf(stderr, "Looking for %d-cycle on cuckoo%d(\"%s\",%d", PROOFSIZE, NODEBITS, header, nonce);

        if (range > 1)
        {
            fprintf(stderr, "-%d", nonce+range-1);
        }
        fprintf(stderr, ") with 50%% edges, %d*%d buckets, %d trims, and %d thread blocks.\n", NX, NY, tp.ntrims, NX);
    }

    solver_ctx ctx(tp);

    if (will_debug)
    {
        uint64_t bytes = ctx.trimmer->globalbytes();
        int unit;

        for (unit=0; bytes >= 10240; bytes>>=10,unit++) ;

        fprintf(stderr, "Using %d%cB of global memory.\n", (uint32_t)bytes, " KMGT"[unit]);
    }

    uint32_t sum_n_sols = 0;

    for (int r = 0; r < range; r++)
    {
        my_solution[0]=0;
        ctx.set_header_nonce(header, sizeof(header), nonce + r);
        
        if (will_debug)
        {
            fprintf(stderr,"nonce %d k0 k1 k2 k3 %zx %zx %zx %zx\n", nonce+r, ctx.trimmer->sipkeys.k0, ctx.trimmer->sipkeys.k1, ctx.trimmer->sipkeys.k2, ctx.trimmer->sipkeys.k3);
        }
        
        uint32_t n_sols = ctx.solve();
        
        for (unsigned s = 0; s < n_sols; s++)
        {
            uint32_t* prf = &ctx.sols[s * PROOFSIZE];
            
            for (uint32_t i = 0; i < PROOFSIZE; i++)
            {
                char temps[512];
                temps[0]=0;
                sprintf(temps," %jx",(uintmax_t)prf[i]);
                strcat(my_solution, temps);
            }
            
            sum_n_sols += n_sols;
            fprintf(stderr,"Solution%s\n",my_solution);
            my_solution[0]=0;
            
            if (will_debug)
            {
                int pow_rc = verify_solution(prf, &ctx.trimmer->sipkeys);
            
                if (pow_rc == POW_OK)
                {
                  fprintf(stderr, "Verified with cycle_hash ");
                  unsigned char cycle_hash[32];
                  blake2b((void *)cycle_hash, sizeof(cycle_hash), (const void *)prf, sizeof(proof), 0, 0);
            
                  for (int i=0; i<32; i++)
                  {
                      fprintf(stderr, "%02x", cycle_hash[i]);
                  }
                  fprintf(stderr, "\n");
                }
                else
                {
                    fprintf(stderr,"FAILED due to %s\n", errstr[pow_rc]);
                }
            }        
        }
    }
    if (will_debug)
    {
        fprintf(stderr, "%d total solutions with %d nonces\n", sum_n_sols,range);
        return 0;
    }
    fprintf(stderr, "%d total solutions\n", sum_n_sols);
    return 0;
}
