% 实验3：仿真结果导出绘图
% 生成 fig3_2 路面输入、fig3_3 车身加速度时域、fig3_4 加速度PSD
clear; clc; close all;
cd('C:\Users\FrostStarInquire\Desktop\matlab\exp3');

% ---------- 方法二模型仿真（与方法一结果一致，取其二） ----------
data;
sim('exp3_suspension_m2');

% ---------- 变步长 -> 均匀网格重采样 ----------
tu = (0:0.001:30)';
u_i   = interp1(t_out, u_out, tu, 'linear');
as_i  = interp1(t_out, as_out, tu, 'linear');
Fs = 1000;

% ---------- 图1：A 级随机路面输入 ----------
figure;
plot(tu, u_i, 'b-');
title('A级随机路面位移输入 u(t)');
xlabel('时间 (s)'); ylabel('路面位移 (m)');
grid on;

% ---------- 图2：车身振动加速度时域 ----------
figure;
plot(tu, as_i, 'b-');
title('车身振动加速度时域波形 z_{s}''');
xlabel('时间 (s)'); ylabel('加速度 (m/s^2)');
grid on;

% ---------- 图3：车身加速度功率谱密度 ----------
nfft = 4096;
win = hanning(nfft);
noverlap = nfft/2;
try
    [Pxx, f] = pwelch(as_i, win, noverlap, nfft, Fs);
catch
    [Pxx, f] = psd(as_i, nfft, Fs);
end
w = 2*pi*f;                          % Hz -> rad/s
Pw = Pxx / (2*pi);                   % 每rad/s功率密度

figure;
plot(w, Pw, 'b-', 'LineWidth', 1.2);
title('车身振动加速度功率谱密度 (PSD)');
xlabel('角频率 (rad/s)'); ylabel('PSD ((m/s^2)^2/(rad/s))');
grid on;
xlim([0 120]);
% 标注定权共振峰
[wmax, imax] = max(Pw);
hold on;
plot(w(imax), wmax, 'rv', 'MarkerFaceColor', 'r', 'MarkerSize', 8);
text(w(imax)+4, wmax, ['峰1: ', num2str(w(imax), '%.1f'), ' rad/s (车身模态)'], 'FontSize', 9);
% 找 >20 rad/s 后的次峰（车轮模态）
idx = find(w > 20);
[w2, i2] = max(Pw(idx));
w2p = w(idx(i2));
plot(w2p, w2, 'rv', 'MarkerFaceColor', 'r', 'MarkerSize', 8);
text(w2p+4, w2, ['峰2: ', num2str(w2p, '%.1f'), ' rad/s (车轮模态)'], 'FontSize', 9);
hold off;

% ---------- 导出 ----------
print(gcf, '-dpng', 'fig3_4.png');
close; figure(2); print(gcf, '-dpng', 'fig3_3.png');
close; figure(1); print(gcf, '-dpng', 'fig3_2.png');
close all;

% ---------- 关键数值输出 ----------
disp(['路面位移 max|u| = ', num2str(max(abs(u_i)), '%.4f'), ' m']);
disp(['车身加速度 std = ', num2str(std(as_i), '%.4f'), ' m/s^2,  max = ', num2str(max(abs(as_i)), '%.4f')]);
disp(['峰1(车身模态) = ', num2str(w(imax), '%.1f'), ' rad/s = ', num2str(w(imax)/2/pi, '%.2f'), ' Hz']);
disp(['峰2(车轮模态) = ', num2str(w2p, '%.1f'), ' rad/s = ', num2str(w2p/2/pi, '%.2f'), ' Hz']);
disp('理论无阻尼固有频率 |eig(A)| rad/s:'); disp(abs(eig(A))');
disp('FIGS_SAVED');
