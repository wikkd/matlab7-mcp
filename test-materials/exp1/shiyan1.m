% 实验1：5Hz 正弦与余弦信号生成与可视化
clear; clc; close all;
fs = 100;% 采样频率 100Hz
t = 0 : 1/fs : 1;% 时间向量 0~1s
f0 = 5;% 信号频率 5Hz
% 信号生成
y_sin = sin(2*pi*f0*t);
y_cos = cos(2*pi*f0*t);
% 同图绘制
figure('Name','信号可视化','NumberTitle','off');
hold on;
plot(t, y_sin, 'b-','LineWidth',1.5);
plot(t, y_cos, 'r--','LineWidth',1.5);
hold off;
% 标注
title('5Hz 正弦与余弦信号对比');
xlabel('时间 t (s)');
ylabel('幅度');
legend('正弦信号 sin','余弦信号 cos');
grid on;
axis([0 0.5 -1.2 1.2]);
