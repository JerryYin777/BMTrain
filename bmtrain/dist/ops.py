from typing import Literal
import torch
from ..global_var import config
from ..nccl import allGather as ncclAllGather
from ..nccl import allReduce as ncclAllReduce

class OpAllGather(torch.autograd.Function):
    @staticmethod
    def forward(ctx, input : torch.Tensor):
        if not input.contiguous():
            input = input.contiguous()
        output = torch.empty( (config['world_size'],) + input.size(), dtype=input.dtype, device=input.device)

        offs = input.storage_offset()
        
        ncclAllGather(
            input.storage()[offs: offs + input.numel()],
            output.storage(),
            config['comm']
        )
        return output

    @staticmethod
    def backward(ctx, grad_output):
        return grad_output[config['rank']]

def all_gather(x : torch.Tensor):
    assert x.is_cuda
    return OpAllGather.apply(x)

class OpAllReduce(torch.autograd.Function):
    @staticmethod
    def forward(ctx, input : torch.Tensor, op: Literal['sum', 'prod', 'max', 'min', 'avg']):
        if not input.contiguous():
            input = input.contiguous()
        output = torch.empty( input.size(), dtype=input.dtype, device=input.device)

        offs = input.storage_offset()
        
        ncclAllReduce(
            input.storage()[offs: offs + input.numel()],
            output.storage(),
            op,
            config['comm']
        )
        ctx.op = op

        if op in ["sum", "avg"]:
            pass
        elif op in ["max", "min"]:
            ctx.save_for_backward( input != output )
        else:
            ctx.save_for_backward( output / input )
        return output

    @staticmethod
    def backward(ctx, grad_output):
        if ctx.op == "sum":
            return grad_output, None
        elif ctx.op == "avg":
            return grad_output / config['world_size'], None
        elif ctx.op in ["max", "min"]:
            return torch.masked_fill(grad_output, ctx.saved_tensors[0], 0), None
        else:
            return grad_output * ctx.saved_tensors[0], None

def all_reduce(x : torch.Tensor, op: Literal['sum', 'prod', 'max', 'min', 'avg']):
    assert x.is_cuda
    return OpAllReduce.apply(x, op)


            
