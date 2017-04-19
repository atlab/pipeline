%{
# Improved Monet stimulus: pink noise with periods of coherent motion
-> stimulus.Condition
-----
fps                         : decimal(6,3)                 # display refresh rate
duration                    : decimal(6,3)                 # (s) trial duration
rng_seed                    : double                       # random number generator seed
pattern_width               : smallint                     # pixel size of the resulting pattern
pattern_aspect              : float                        # the aspect ratio of the pattern
pattern_upscale             : tinyint                      # integer upscale factor of the pattern
temp_bandwidth              : decimal(4,2)                 # (Hz) temporal bandwidth of the stimulus
ori_coherence               : decimal(4,2)                 # 1=unoriented noise. pi/ori_coherence = bandwidth of orientations.
ori_fraction                : float                        # fraction of time coherent orientation is on
ori_mix                     : float                        # mixin-coefficient of orientation biased noise
n_dirs                      : smallint                     # number of directions
speed                       : float                        # (units/s)  where unit is display width
directions                  : longblob                     # computed directions of motion in degrees
onsets                      : blob                         # (s) computed
movie                       : longblob                     # (computed) uint8 movie
%}

classdef Monet2 < dj.Manual & stimulus.core.Visual
    
    properties(Constant)
        variation = 'dimitri-1'
    end
    
    methods(Static)
        function test
            cond.fps = 60;
            cond.duration = 30;
            cond.rng_seed = 1;
            cond.pattern_width = 64;
            cond.pattern_aspect = 1.7;
            cond.pattern_upscale = 3;
            cond.ori_coherence = 2.5;
            cond.ori_fraction = 0.4;
            cond.temp_bandwidth = 4;
            cond.n_dirs = 16;
            cond.ori_mix = 1;
            cond.speed = 0.5;
            
            tic
            cond = stimulus.Monet2.make(cond);
            toc
            
            v = VideoWriter('Monet2', 'MPEG-4');
            v.FrameRate = cond.fps;
            v.Quality = 100;
            open(v)
            writeVideo(v, permute(cond.movie, [1 2 4 3]));
            close(v)
        end
        
        function cond = make(cond)
            
            function y = hann(q)
                % circuar hanning mask with symmetric opposite lobes
                y = (0.5 + 0.5*cos(q)).*(abs(q)<pi);
            end

            assert(~verLessThan('matlab','9.1'), 'Please upgrade MATLAB to R2016b or better')  % required for no bsxfun
            
            period = cond.duration/cond.n_dirs;
            nFrames = round(cond.duration*cond.fps/2)*2;
            targetSize = [round(cond.pattern_width/cond.pattern_aspect/2)*2, cond.pattern_width, nFrames];
            
            assert(~any(bitand(targetSize,1)), 'all movie dimensions must be even')
            r = RandStream.create('mt19937ar','NormalTransform', ...
                'Ziggurat', 'Seed', cond.rng_seed);
            m = r.randn(targetSize + cond.pattern_upscale*[2 2 0]);  % movie with padding to prevent edge correlations
            
            % apply temporal filter in time domain
            semi = round(cond.fps/cond.temp_bandwidth);
            k = hamming(semi*2+1);
            k = k(1:semi+1);
            k = k/sum(k);
            m = convn(m, permute(k, [3 2 1]), 'same');
            
            % upsample and interpolate
            factor = cond.pattern_upscale;
            m = upsample(permute(m, [2 1 3]), factor, round(factor/2))*factor;
            m = upsample(permute(m, [2 1 3]), factor, round(factor/2))*factor;
            sz = size(m);
            
            
            % apply directions and offsets
            cond.directions = (r.randperm(cond.n_dirs)-1)/cond.n_dirs*360;
            t = (0:sz(3)-1)/cond.fps;
            cond.onsets = ((0.5:cond.n_dirs) - cond.ori_fraction/2)*period;
            direction = nan(size(t));
            for i = 1:length(cond.onsets)
                direction(t > cond.onsets(i) & t<=cond.onsets(i) + period*cond.ori_fraction) = cond.directions(i);
            end
            
            % make interpolation kernel
            [fy,fx] = ndgrid(...
                ifftshift((-floor(sz(1)/2):floor(sz(1)/2-0.5))*2*pi/sz(1)), ...
                ifftshift((-floor(sz(2)/2):floor(sz(2)/2-0.5))*2*pi/sz(2)));
            kernel_sigma = factor;
            finterp = exp(-(fy.^2 + fx.^2)*kernel_sigma.^2/2);
            
            % apply coherent orientation selectivity and orthogonal motion
            m = fft2(m);
            motion = 1;
            speed = cond.pattern_width*cond.speed/cond.fps;  % in pattern widths per frame
            mix = cond.ori_mix * (cond.ori_coherence > 1);
            for i = 1:sz(3)
                fmask = motion.*finterp;  % apply motion first so technically motion starts in next frame
                if ~isnan(direction(i))
                    ori = direction(i)*pi/180+pi/2;   % following clock directions
                    theta = mod(atan2(fx,fy) + ori, pi) - pi/2;
                    fmask = fmask.*(1-mix + mix*sqrt(cond.ori_coherence).*hann(theta*cond.ori_coherence));
                    motion = motion .* exp(1j*speed*(cos(ori).*fx + sin(ori).*fy));   % negligible error accumulates
                end
                m(:,:,i) = fmask.*m(:,:,i);
            end
            m = real(ifft2(m))*2.5;
            cond.movie = uint8((real(m)+0.5)*255);
        end
    end
    
    methods
        function showTrial(self, cond)
            % verify that pattern parameters match display settings
            assert(~isempty(self.fps), 'Cannot obtain the refresh rate')
            assert(abs(self.fps - cond.fps)/cond.fps < 0.05, 'incorrect monitor frame rate')
            assert((self.rect(3)/self.rect(4) - cond.pattern_aspect)/cond.pattern_aspect < 0.05, 'incorrect pattern aspect')
            
            % blank the screen if there is a blanking period
            if cond.pre_blank_period>0
                opts.logFlips = false;
                self.flip(struct('checkDroppedFrames', false))
                WaitSecs(cond.pre_blank_period);
            end
            
            % play movie
            opts.logFlips = true;
            for i=1:size(cond.movie,3)
                tex = Screen('MakeTexture', self.win, cond.movie(:,:,i));
                Screen('DrawTexture',self.win, tex, [], self.rect)
                self.flip(struct('checkDroppedFrames', i>1))
                Screen('close',tex)
            end
        end
    end
end



