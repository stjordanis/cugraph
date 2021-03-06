/*
 * Copyright (c) 2019, NVIDIA CORPORATION.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

// snmg pagerank
// Author: Alex Fender afender@nvidia.com
 
#pragma once
#include "cub/cub.cuh"
#include <omp.h>
#include "utilities/graph_utils.cuh"
#include "snmg/utils.cuh"
#include "snmg/blas/spmv.cuh"
//#define SNMG_DEBUG

namespace cugraph
{

  template<typename IndexType, typename ValueType>
__global__ void __launch_bounds__(CUDA_MAX_KERNEL_THREADS)
transition_kernel(const size_t e,
                  const IndexType *ind,
                  const IndexType *degree,
                  ValueType *val) {
  for (auto i = threadIdx.x + blockIdx.x * blockDim.x; 
       i < e; 
       i += gridDim.x * blockDim.x)
    val[i] = 1.0 / degree[ind[i]];
}

template <typename IndexType, typename ValueType>
class SNMGpagerank 
{ 
  private:
    size_t v_glob; //global number of vertices
    size_t v_loc;  //local number of vertices
    size_t e_loc;  //local number of edges
    int id; // thread id
    int nt; // number of threads
    ValueType alpha; // damping factor
    SNMGinfo env;  //info about the snmg env setup
    cudaStream_t stream;  
    
    //Vertex offsets for each partition. 
    //This information should be available on all threads/devices
    //part_offsets[device_id] contains the global ID 
    //of the first vertex of the partion owned by device_id. 
    //part_offsets[num_devices] contains the global number of vertices
    size_t* part_off; 
    
    // local CSR matrix
    IndexType * off;
    IndexType * ind;
    ValueType * val;

    // vectors of size v_glob 
    ValueType * bookmark; // constant vector with dangling node info

    bool is_setup;

  public: 
    SNMGpagerank(SNMGinfo & env_, size_t* part_off_, 
                 IndexType * off_, IndexType * ind_) : 
                 env(env_), part_off(part_off_), off(off_), ind(ind_) { 
      id = env.get_thread_num();
      nt = env.get_num_threads(); 
      v_glob = part_off[nt];
      v_loc = part_off[id+1]-part_off[id];
      IndexType tmp_e;
      cudaMemcpy(&tmp_e, &off[v_loc], sizeof(IndexType),cudaMemcpyDeviceToHost);
      cudaCheckError();
      e_loc = tmp_e;
      stream = nullptr;
      is_setup = false;
      ALLOC_TRY ((void**)&bookmark,   sizeof(ValueType) * v_glob, stream);
      ALLOC_TRY ((void**)&val, sizeof(ValueType) * e_loc, stream);
    } 
    ~SNMGpagerank() { 
      ALLOC_FREE_TRY(bookmark, stream); 
      ALLOC_FREE_TRY(val, stream);
    }

    void transition_vals(const IndexType *degree) {
      int threads = min(static_cast<IndexType>(e_loc), 256);
      int blocks = min(static_cast<IndexType>(32*env.get_num_sm()), CUDA_MAX_BLOCKS);
      transition_kernel<IndexType, ValueType> <<<blocks, threads>>> (e_loc, ind, degree, val);
      cudaCheckError();
    }

    void flag_leafs(const IndexType *degree) {
      int threads = min(static_cast<IndexType>(v_glob), 256);
      int blocks = min(static_cast<IndexType>(32*env.get_num_sm()), CUDA_MAX_BLOCKS);
      flag_leafs_kernel<IndexType, ValueType> <<<blocks, threads>>> (v_glob, degree, bookmark);
      cudaCheckError();
    }    


    // Artificially create the google matrix by setting val and bookmark
    void setup(ValueType _alpha) {
      if (!is_setup) {
        alpha=_alpha;
        ValueType zero = 0.0; 
        IndexType *degree;
        ALLOC_TRY ((void**)&degree,   sizeof(IndexType) * v_glob, stream);
        
        // TODO snmg degree
        int nthreads = min(static_cast<IndexType>(e_loc), 256);
        int nblocks = min(static_cast<IndexType>(32*env.get_num_sm()), CUDA_MAX_BLOCKS);
        degree_coo<IndexType, IndexType><<<nblocks, nthreads>>>(v_glob, e_loc, ind, degree);
        
        // Update dangling node vector
        fill(v_glob, bookmark, zero);
        flag_leafs(degree);
        update_dangling_nodes(v_glob, bookmark, alpha);

        // Transition matrix
        transition_vals(degree);

        //exit
        ALLOC_FREE_TRY(degree, stream);
        is_setup = true;
      }
      else
        throw std::string("Setup can be called only once");
    }

    // run the power iteration on the google matrix
    void solve (int max_iter, ValueType ** pagerank) {
      if (is_setup) {
        ValueType  dot_res;
        ValueType one = 1.0;
        ValueType *pr = pagerank[id];
        fill(v_glob, pagerank[id], one/v_glob);
        dot_res = dot( v_glob, bookmark, pr);
        SNMGcsrmv<IndexType,ValueType> spmv_solver(env, part_off, off, ind, val, pagerank);
        for (auto i = 0; i < max_iter; ++i) {
          spmv_solver.run(pagerank);
          scal(v_glob, alpha, pr);
          addv(v_glob, dot_res * (one/v_glob) , pr);
          dot_res = dot( v_glob, bookmark, pr);
          scal(v_glob, one/nrm2(v_glob, pr) , pr);
        }
        scal(v_glob, one/nrm1(v_glob,pr), pr);
      }
      else {
          throw std::string("Solve was called before setup");
      }
    }
};

} //namespace cugraph
