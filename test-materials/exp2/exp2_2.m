% 实验2 任务2：信号截取与矩阵拼接
clear; clc; close all;
t = 0:0.01:1;               % 时间向量
x = sin(2*pi*5*t);          % 5Hz正弦信号
y = 2 * x;                  % 幅度缩放后的信号
% 截取信号的前50个点和后50个点
y_part1 = y(1:50);          % 取前50个点（索引1到50）
y_part2 = y(end-49:end);    % 取后50个点（end为最后一个索引）
% 纵向拼接两段信号
y_new = [y_part1; y_part2]; % 行向量纵向拼接成2行矩阵
% 查看拼接后矩阵的维度
disp(['拼接后矩阵维度: ', num2str(size(y_new))]);
% 注：[A;B]为纵向拼接（行数相加），[A,B]为横向拼接（列数相加）
figure;
subplot(2,1,1);
plot(y_part1); title('前50个采样点波形');
subplot(2,1,2);
plot(y_part2); title('后50个采样点波形');
