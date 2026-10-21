% 实验2 任务4：循环逻辑实现信号分段处理
clear; clc; close all;
t = 0:0.01:1;
x = sin(2*pi*5*t);
y = 2 * x;                  % 原始信号
% 循环逻辑实现信号分段处理
segment_len = 20;           % 设定分段长度（每段20个点）
num_segments = fix( length(y) / segment_len );  % 计算总段数，强制整数
seg_mean = zeros(1, num_segments);              % 预分配分段均值数组
for k = 1: num_segments
    start_idx = (k-1)*segment_len + 1;          % 当前段起始索引
    end_idx = k * segment_len;                  % 当前段结束索引
    seg_mean(k) = mean(y(start_idx:end_idx));   % 该段平均值
end
% 绘制分段均值柱状图
figure;
stem(1:num_segments, seg_mean, 'b','MarkerSize', 8);
title('信号分段均值变化趋势');
xlabel('分段编号'); ylabel('段内均值');
grid on;
