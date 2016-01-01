
--[[

This file trains a character-level multi-layer RNN on text data

Code is based on implementation in 
https://github.com/oxford-cs-ml-2015/practical6
but modified to have multi-layer support, GPU support, as well as
many other common model/optimization bells and whistles.
The practical6 code is in turn based on 
https://github.com/wojciechz/learning_to_execute
which is turn based on other stuff in Torch, etc... (long lineage)

]]--

require 'torch'
require 'nn'
require 'nngraph'
require 'optim'
require 'lfs'

require 'util.OneHot'
require 'util.misc'
local DataLoader = require 'util.PaddedLineSplitLoader'
local model_utils = require 'util.model_utils'
local LSTM = require 'model.LSTM'

cmd = torch.CmdLine()
cmd:text()
cmd:text('Train a character-level language model')
cmd:text()
cmd:text('Options')
-- data
cmd:option('-data_dir','data/tinyshakespeare','data directory. Should contain the file input.txt with input data')
-- model params
cmd:option('-rnn_size', 128, 'size of LSTM internal state')
cmd:option('-num_layers', 2, 'number of layers in the LSTM')
cmd:option('-model', 'lstm', 'for now only lstm is supported. keep fixed')
-- optimization
cmd:option('-learning_rate',2e-3,'learning rate')
cmd:option('-learning_rate_decay',0.97,'learning rate decay')
cmd:option('-learning_rate_decay_after',10,'in number of epochs, when to start decaying the learning rate')
cmd:option('-decay_rate',0.95,'decay rate for rmsprop')
cmd:option('-dropout',0,'dropout for regularization, used after each RNN hidden layer. 0 = no dropout')
cmd:option('-seq_length',50,'number of timesteps to unroll for')
cmd:option('-batch_size',50,'number of sequences to train on in parallel')
cmd:option('-max_epochs',50,'number of full passes through the training data')
cmd:option('-grad_clip',5,'clip gradients at this value')
cmd:option('-train_frac',0.95,'fraction of data that goes into train set')
cmd:option('-val_frac',0.05,'fraction of data that goes into validation set')
            -- test_frac will be computed as (1 - train_frac - val_frac)
cmd:option('-init_from', '', 'initialize network parameters from checkpoint at this path')
-- bookkeeping
cmd:option('-seed',123,'torch manual random number generator seed')
cmd:option('-print_every',1,'how many steps/minibatches between printing out the loss')
cmd:option('-eval_val_every',1000,'every how many iterations should we evaluate on validation data?')
cmd:option('-checkpoint_dir', 'cv', 'output directory where checkpoints get written')
cmd:option('-compress', 1, 'compress data output')
cmd:option('-savefile','lstm','filename to autosave the checkpont to. Will be inside checkpoint_dir/')
cmd:option('-savemodel',1,'save me')
-- GPU/CPU
cmd:option('-gpuid',0,'which gpu to use. -1 = use CPU')
cmd:text()

-- parse input params
opt = cmd:parse(arg)
torch.manualSeed(opt.seed)
-- train / val / test split for data, in fractions
local test_frac = math.max(0, 1 - (opt.train_frac + opt.val_frac))
local split_sizes = {opt.train_frac, opt.val_frac, test_frac} 

-- initialize cunn/cutorch for training on the GPU and fall back to CPU gracefully
if opt.gpuid >= 0 then
    local ok, cunn = pcall(require, 'cunn')
    local ok2, cutorch = pcall(require, 'cutorch')
    if not ok then print('package cunn not found!') end
    if not ok2 then print('package cutorch not found!') end
    if ok and ok2 then
        print('using CUDA on GPU ' .. opt.gpuid .. '...')
        cutorch.setDevice(opt.gpuid + 1) -- note +1 to make it 0 indexed! sigh lua
        cutorch.manualSeed(opt.seed)
    else
        print('If cutorch and cunn are installed, your CUDA toolkit may be improperly configured.')
        print('Check your CUDA toolkit installation, rebuild cutorch and cunn, and try again.')
        print('Falling back on CPU mode')
        opt.gpuid = -1 -- overwrite user setting
    end
end

-- create the data loader class
local loader = DataLoader.create(opt.data_dir, opt.batch_size, opt.seq_length, split_sizes)
local vocab_size = loader.vocab_size  -- the number of distinct characters
local vocab = loader.vocab_mapping
print('vocab size: ' .. vocab_size)
local ivocab = {}
for c,i in pairs(vocab) do ivocab[i] = c end
-- make sure output directory exists
if not path.exists(opt.checkpoint_dir) then lfs.mkdir(opt.checkpoint_dir) end

-- define the model: prototypes for one timestep, then clone them in time
local do_random_init = true
if string.len(opt.init_from) > 0 then
    print('loading an LSTM from checkpoint ' .. opt.init_from)
    local checkpoint = torch.load(opt.init_from)
    protos = checkpoint.protos
    -- make sure the vocabs are the same
    local vocab_compatible = true
    for c,i in pairs(checkpoint.vocab) do 
        if not vocab[c] == i then 
            vocab_compatible = false
        end
    end
    assert(vocab_compatible, 'error, the character vocabulary for this dataset and the one in the saved checkpoint are not the same. This is trouble.')
    -- overwrite model settings based on checkpoint to ensure compatibility
    print('overwriting rnn_size=' .. checkpoint.opt.rnn_size .. ', num_layers=' .. checkpoint.opt.num_layers .. ' based on the checkpoint.')
    opt.rnn_size = checkpoint.opt.rnn_size
    opt.num_layers = checkpoint.opt.num_layers
    do_random_init = false
else
    print('creating an LSTM with ' .. opt.num_layers .. ' layers')
    protos = {}
    protos.rnn = LSTM.lstm(vocab_size, opt.rnn_size, opt.num_layers, opt.dropout)
    protos.criterion = nn.ClassNLLCriterion()
end

-- the initial state of the cell/hidden states
init_state = {}
for L=1,opt.num_layers do
    local h_init = torch.zeros(opt.batch_size, opt.rnn_size)
    if opt.gpuid >=0 then h_init = h_init:cuda() end
    table.insert(init_state, h_init:clone())
    table.insert(init_state, h_init:clone())
end

-- ship the model to the GPU if desired
if opt.gpuid >= 0 then
    for k,v in pairs(protos) do v:cuda() end
end

-- put the above things into one flattened parameters tensor
params, grad_params = model_utils.combine_all_parameters(protos.rnn)

-- initialization
if do_random_init then
params:uniform(-0.08, 0.08) -- small numbers uniform
end

print('number of parameters in the model: ' .. params:nElement())
-- make a bunch of clones after flattening, as that reallocates memory
clones = {}
for name,proto in pairs(protos) do
    print('cloning ' .. name)
    clones[name] = model_utils.clone_many_times(proto, opt.seq_length, not proto.parameters)
end

-- evaluate the loss over an entire split
-- safe to use the same rnn for all the forward passes
function eval_split(split_index, max_batches)
    print('evaluating loss over split index ' .. split_index)
    local n = loader.split_sizes[split_index]
    if max_batches ~= nil then n = math.min(max_batches, n) end

    loader:reset_batch_pointer(split_index) -- move batch iteration pointer for this split to front
    local loss = 0
    local rnn_state = {[0] = init_state}
    local sampleSize = 0
    
    for i = 1,n do -- iterate over batches in the split
        -- fetch a batch
        local x, y = loader:next_batch(split_index)
        if opt.gpuid >= 0 then -- ship the input arrays to GPU
            -- have to convert to float because integers can't be cuda()'d
            x = x:float():cuda()
            y = y:float():cuda()
        end
        -- forward pass
        sampleSize = x:size(2)
        for t=1,sampleSize do
            clones.rnn[1]:evaluate() -- for dropout proper functioning
            local lst = clones.rnn[1]:forward{x[{{}, t}], unpack(rnn_state[t-1])}
            rnn_state[t] = {}
            for i=1,#init_state do table.insert(rnn_state[t], lst[i]) end
            prediction = lst[#lst] 
            loss = loss + clones.criterion[1]:forward(prediction, y[{{}, t}])
        end
        -- carry over lstm state
        --rnn_state[0] = rnn_state[#rnn_state]
        rnn_state = {[0] = init_state}
    end

    loss = loss / sampleSize / n
    return loss
end

function sample_sequence(protos, length) 
    protos.rnn:evaluate()
    -- fill with uniform probabilities over characters (? hmm)
    -- gprint('missing seed text, using uniform probability over first character')
    -- gprint('--------------------------')
    print("evaluate some test sequence")
    -- local prediction = torch.ShortTensor(1, #ivocab):fill(1)/(#ivocab)
    -- this is for dummy
    -- local prev_char = torch.ShortTensor{vocab['F']}
    local prev_char = torch.ShortTensor{24}
    io.write(ivocab[prev_char[1]])
    if opt.gpuid >= 0 then prediction = prediction:cuda() end
    -- use argmax
    local current_state = {}
    for L = 1,opt.num_layers do
        -- c and h for all layers
        local h_init = torch.zeros(1, opt.rnn_size)
        if opt.gpuid >= 0 then h_init = h_init:cuda() end
        table.insert(current_state, h_init:clone())
        table.insert(current_state, h_init:clone())
    end
    local state_size = #current_state
    for i=1, length do
        local lst = protos.rnn:forward{prev_char, unpack(current_state)}
        current_state = {}
        for i=1,state_size do table.insert(current_state, lst[i]) end
        prediction = lst[#lst]
        local _, prev_char_ = prediction:max(2)
        prev_char = prev_char_:resize(1):short()
        -- print(ivocab[prev_char[1]] .. ' prob ' .. prediction[1][prev_char[1]])
        io.write(ivocab[prev_char[1]])
    end
end

-- do fwd/bwd and return loss, grad_params
local init_state_global = clone_list(init_state)
function feval(x)
    if x ~= params then
        params:copy(x)
    end
    grad_params:zero()

    ------------------ get minibatch -------------------
    local x, y = loader:next_batch(1)
    if opt.gpuid >= 0 then -- ship the input arrays to GPU
        -- have to convert to float because integers can't be cuda()'d
        x = x:float():cuda()
        y = y:float():cuda()
    end
    ------------------- forward pass -------------------
    local loss = 0
    -- looks like stuff outside of seq_length didn't matter?
    -- both wojzaremba and karpathy didn't preserve drnn after propagated seq_length step
    local sampleSize = x:size(2)
    local trainingBatch = math.floor(sampleSize / opt.seq_length)
    for b=1, trainingBatch+1 do
        local rnn_state = {[0] = init_state_global}
        local predictions = {}           -- softmax outputs
        local offset = (b-1) * opt.seq_length
        if b == trainingBatch+1 then
            offEnd = sampleSize - trainingBatch * opt.seq_length
        else 
            offEnd = opt.seq_length
        end
        for t=1,offEnd do
            local dataPos = offset + t
            clones.rnn[t]:training() -- make sure we are in correct mode (this is cheap, sets flag)
            local lst = clones.rnn[t]:forward{x[{{}, dataPos}], unpack(rnn_state[t-1])}
            rnn_state[t] = {}
            for i=1,#init_state do table.insert(rnn_state[t], lst[i]) end -- extract the state, without output
            predictions[t] = lst[#lst] -- last element is the prediction
            loss = loss + clones.criterion[t]:forward(predictions[t], y[{{}, dataPos}])
        end
        ------------------ backward pass -------------------
        -- initialize gradient at time t to be zeros (there's no influence from future)
        local drnn_state = {[offEnd] = clone_list(init_state, true)} -- true also zeros the clones
        for t=offEnd,1,-1 do
            local dataPos = offset + t
            -- backprop through loss, and softmax/linear
            local doutput_t = clones.criterion[t]:backward(predictions[t], y[{{}, dataPos}])
            table.insert(drnn_state[t], doutput_t)
            local dlst = clones.rnn[t]:backward({x[{{}, dataPos}], unpack(rnn_state[t-1])}, drnn_state[t])
            drnn_state[t-1] = {}
            for k,v in pairs(dlst) do
                if k > 1 or b ~= 1 then -- k == 1 is gradient on x, which we dont need
                    -- note we do k-1 because first item is dembeddings, and then follow the 
                    -- derivatives of the state, starting at index 2. I know...
                    drnn_state[t-1][k-1] = v
                end
            end
        end
        ------------------------ misc ----------------------
        -- transfer final state to initial state (BPTT)
        init_state_global = rnn_state[#rnn_state] -- NOTE: I don't think this needs to be a clone, right?
    end
    loss = loss / sampleSize
    -- clip gradient element-wise
    grad_params:clamp(-opt.grad_clip, opt.grad_clip)
    return loss, grad_params
end

-- start optimization here
train_losses = {}
val_losses = {}
local val_loss = eval_split(2) -- 2 = validation
val_losses[0] = val_loss
print('initial validation loss is ' .. val_loss)
local optim_state = {learningRate = opt.learning_rate, alpha = opt.decay_rate}
local iterations = opt.max_epochs * loader.ntrain
local iterations_per_epoch = loader.ntrain
local loss0 = nil
for i = 1, iterations do
    local epoch = i / loader.ntrain

    local timer = torch.Timer()
    local _, loss = optim.rmsprop(feval, params, optim_state)
    local time = timer:time().real

    local train_loss = loss[1] -- the loss is inside a list, pop it
    train_losses[i] = train_loss

    -- exponential learning rate decay
    if i % loader.ntrain == 0 and opt.learning_rate_decay < 1 then
        if epoch >= opt.learning_rate_decay_after then
            local decay_factor = opt.learning_rate_decay
            optim_state.learningRate = optim_state.learningRate * decay_factor -- decay it
            print('decayed learning rate by a factor ' .. decay_factor .. ' to ' .. optim_state.learningRate)
        end
    end

    -- every now and then or on last iteration
    if i % math.floor(opt.eval_val_every* iterations_per_epoch) == 0 or i == iterations then
        -- evaluate loss on validation data
        local val_loss = eval_split(2) -- 2 = validation
        val_losses[i] = val_loss
        print("validation loss at " .. i .. ' is ' .. val_loss)
        sample_sequence(protos, 10)

        if i ~= 1 and opt.savemodel == 1 then 
            local savefile = string.format('%s/lm_%s_epoch%.2f_%.4f.t7', opt.checkpoint_dir, opt.savefile, epoch, val_loss)
            print('saving checkpoint to ' .. savefile)
            local checkpoint = {}
            checkpoint.protos = protos
            checkpoint.opt = opt
            checkpoint.train_losses = train_losses
            checkpoint.val_loss = val_loss
            checkpoint.val_losses = val_losses
            checkpoint.i = i
            checkpoint.epoch = epoch
            checkpoint.vocab = loader.vocab_mapping
            torch.save(savefile, checkpoint)
            if opt.compress == 1 then
                os.execute("pigz " .. savefile)
            end
        end
    end

    if i % opt.print_every == 0 then
        print(string.format("%d/%d (epoch %.3f), train_loss = %6.8f, grad/param norm = %6.4e, time/batch = %.2fs", i, iterations, epoch, train_loss, grad_params:norm() / params:norm(), time))
    end
   
    if i % 10 == 0 then collectgarbage() end

    -- handle early stopping if things are going really bad
    if loss0 == nil then loss0 = loss[1] end
    if loss[1] > loss0 * 3 then
        print('loss is exploding, aborting.')
        break -- halt
    end
end

