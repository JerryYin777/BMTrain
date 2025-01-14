#include <cuda_fp16.h>
#include <cuda_bf16.h>
#include "reduce.cuh"
#include <cstdint>
#include<cuda_runtime_api.h>

namespace {
// blocks <m>,      threads<1024>
__global__ void cross_entropy_forward(
    int64_t n,
    const half *input,      // (m, n)
    const int32_t *target,  // (m)
    half *softmax,          // (m, n)
    float *output,          // (m)
    int32_t ignore_index
) {
    int64_t base_idx = blockIdx.x * n;

    float local_max = -INFINITY;
    for (int64_t i = threadIdx.x; i < n; i += blockDim.x) {
        local_max = fmaxf(__half2float(input[base_idx + i]), local_max);
    }

    local_max = fmaxf(block_allreduce_max(local_max), -1e6);
    
    float local_sum = 0;
    for (int64_t i = threadIdx.x; i < n; i += blockDim.x) {
        local_sum += expf(__half2float(input[base_idx + i]) - local_max);
    }
    local_sum = block_allreduce_sum(local_sum) + 1e-10; // avoid nan
    
    for (int64_t i = threadIdx.x; i < n; i += blockDim.x) {
        softmax[base_idx + i] = __float2half( expf(__half2float(input[base_idx + i]) - local_max) / local_sum );
    }

    if (threadIdx.x == 0) {
        if (target[blockIdx.x] != ignore_index) {
            output[blockIdx.x] = -__half2float(input[base_idx + target[blockIdx.x]]) + local_max + logf(local_sum);
        } else {
            output[blockIdx.x] = 0;
        }
    }
}

// blocks <m>,      threads<1024>
__global__ void cross_entropy_backward(
    int64_t n,
    const float *grad_output,   // (m)
    const int32_t *target,      // (m)
    const half *softmax,        // (m, n)
    half *grad_input,           // (m, n)
    int32_t ignore_index
) {
    int64_t base_idx = blockIdx.x * n;

    int32_t t = target[blockIdx.x];
    if (t == ignore_index) {
        half v = __float2half(0.);
        for (int64_t i = threadIdx.x; i < n; i += blockDim.x) {
            grad_input[base_idx + i] = v;
        }
    }
    else {
        half v = __float2half(grad_output[blockIdx.x]);
        for (int64_t i = threadIdx.x; i < n; i += blockDim.x) {
            grad_input[base_idx + i] = i==t ? __hsub(__hmul(softmax[base_idx + i], v), v) : __hmul(softmax[base_idx + i], v);
        }
    }
}

// blocks <m>,      threads<1024>
__global__ void cross_entropy_forward_inplace(
    int64_t n,
    half *x,                // (m, n)
    const int32_t *target,  // (m)
    float *output,          // (m)
    int32_t ignore_index
) {
    int64_t base_idx = blockIdx.x * n;

    float local_max = -INFINITY;
    for (int64_t i = threadIdx.x; i < n; i += blockDim.x) {
        local_max = fmaxf(__half2float(x[base_idx + i]), local_max);
    }
    local_max = fmaxf(block_allreduce_max(local_max), -1e6);
    
    float local_sum = 0;
    for (int64_t i = threadIdx.x; i < n; i += blockDim.x) {
        local_sum += expf(__half2float(x[base_idx + i]) - local_max);
    }
    local_sum = block_allreduce_sum(local_sum) + 1e-10; // avoid nan

    if (threadIdx.x == 0) {
        if (target[blockIdx.x] != ignore_index) {
            output[blockIdx.x] = -__half2float(x[base_idx + target[blockIdx.x]]) + local_max + logf(local_sum);
        } else {
            output[blockIdx.x] = 0;
        }
    }

    __syncthreads();
    
    for (int64_t i = threadIdx.x; i < n; i += blockDim.x) {
        x[base_idx + i] = __float2half( expf(__half2float(x[base_idx + i]) - local_max) / local_sum );
    }
}

// blocks <m>,      threads<1024>
__global__ void cross_entropy_backward_inplace(
    int64_t n,
    const float *grad_output,   // (m)
    const int32_t *target,      // (m)
    half *x,                    // (m, n)
    int32_t ignore_index
) {
    int64_t base_idx = blockIdx.x * n;

    int32_t t = target[blockIdx.x];
    if (t == ignore_index) {
        half v = __float2half(0.);
        for (int64_t i = threadIdx.x; i < n; i += blockDim.x) {
            x[base_idx + i] = v;
        }
    }
    else {
        half v = __float2half(grad_output[blockIdx.x]);
        __syncthreads();
        for (int64_t i = threadIdx.x; i < n; i += blockDim.x) {
            x[base_idx + i] = i==t ? __hsub(__hmul(x[base_idx + i], v), v) : __hmul(x[base_idx + i], v);
        }
    }
}

}

void cross_entropy_forward_launcher(
    int32_t m, int32_t n,
    std::uintptr_t input,
    std::uintptr_t target,
    std::uintptr_t softmax,
    std::uintptr_t output,
    int32_t ignore_index,
    std::uintptr_t stream
) {
    auto input_ptr = reinterpret_cast<half*>(input);
    auto target_ptr = reinterpret_cast<int32_t*>(target);
    auto softmax_ptr = reinterpret_cast<half*>(softmax);
    auto output_ptr = reinterpret_cast<float*>(output);
    int32_t threads = 1024;
    cross_entropy_forward<<<m, threads, 0, reinterpret_cast<cudaStream_t>(stream)>>>(n, input_ptr, target_ptr, softmax_ptr, output_ptr, ignore_index);
}

void cross_entropy_backward_launcher(
    int32_t m, int32_t n,
    std::uintptr_t grad_output,
    std::uintptr_t target,
    std::uintptr_t softmax,
    std::uintptr_t grad_input,
    int32_t ignore_index,
    std::uintptr_t stream
) {
    // auto output_ptr = grad_output.data_ptr<float>();
    auto output_ptr = reinterpret_cast<float*>(grad_output);
    // auto target_ptr = target.data_ptr<int32_t>();
    auto target_ptr = reinterpret_cast<int32_t*>(target);
    auto softmax_ptr = reinterpret_cast<half*>(softmax);
    auto input_ptr = reinterpret_cast<half*>(grad_input);
    int32_t threads = 1024;
    cross_entropy_backward<<<m, threads, 0, reinterpret_cast<cudaStream_t>(stream)>>>(n, output_ptr, target_ptr, softmax_ptr, input_ptr, ignore_index);
}

void cross_entropy_forward_inplace_launcher(
    int32_t m, int32_t n,
    std::uintptr_t x,
    std::uintptr_t target,
    std::uintptr_t output,
    int32_t ignore_index,
    std::uintptr_t stream
) {
    // auto x_ptr = reinterpret_cast<half*>(x.data_ptr<at::Half>());
    auto x_ptr = reinterpret_cast<half*>(x);
    // auto target_ptr = target.data_ptr<int32_t>();
    auto target_ptr = reinterpret_cast<int32_t*>(target);
    // auto output_ptr = output.data_ptr<float>();
    auto output_ptr = reinterpret_cast<float*>(output);
    int32_t threads = 1024;
    // auto stream = at::cuda::getCurrentCUDAStream();
    cross_entropy_forward_inplace<<<m, threads, 0, reinterpret_cast<cudaStream_t>(stream)>>>(n, x_ptr, target_ptr, output_ptr, ignore_index);
}

void cross_entropy_backward_inplace_launcher(
    int32_t m, int32_t n,
    std::uintptr_t grad_output,
    std::uintptr_t target,
    std::uintptr_t x,
    int32_t ignore_index,
    std::uintptr_t stream
) {
    // auto output_ptr = grad_output.data_ptr<float>();
    auto output_ptr = reinterpret_cast<float*>(grad_output);
    // auto target_ptr = target.data_ptr<int32_t>();
    auto target_ptr = reinterpret_cast<int32_t*>(target);
    // auto x_ptr = reinterpret_cast<half*>(x.data_ptr<at::Half>());
    auto x_ptr = reinterpret_cast<half*>(x);
    int32_t threads = 1024;
    // auto stream = at::cuda::getCurrentCUDAStream();
    cross_entropy_backward_inplace<<<m, threads, 0, reinterpret_cast<cudaStream_t>(stream)>>>(n, output_ptr, target_ptr, x_ptr, ignore_index);
}