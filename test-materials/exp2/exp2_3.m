% 实验2 任务3：分支逻辑实现信号限幅
clear; clc; close all;
t = 0:0.01:1;
x = sin(2*pi*5*t);
y = 2 * x;                  % 原始信号（幅度范围-2到2）
% 分支逻辑实现信号限幅处理（限幅范围正负1）
y_clip = zeros(size(y));    % 预分配限幅后信号数组
for i = 1:length(y)         % 遍历信号每个元素
    if y(i) > 1             % 超过+1的部分
        y_clip(i) = 1;      % 钳制到+1
    elseif y(i) < -1        % 低于-1的部分
        y_clip(i) = -1;     % 钳制到-1
    else                    % 在正负1范围内的保持不变
        y_clip(i) = y(i);
    end
end
% 绘制y与y_clip的对比图
figure;
plot(t, y, 'b--', t, y_clip, 'r-', 'LineWidth', 1.5);
title('原始信号与限幅信号对比');
xlabel('时间 (s)'); ylabel('幅度');
legend('原始信号y', '限幅信号y_clip');
grid on;
% 可观察到波形峰值被钳制在正负1之间
