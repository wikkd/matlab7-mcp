
% 百公里电耗与理论续航
dist_km = trapz(t, v_kmh)/3600;             % 工况总里程 km
cons_100 = E_total / dist_km * 100;          % 百公里电耗 kWh/100km
range_km = Ebat / cons_100 * 100;            % 理论续航 km

fprintf('===== 车辆CLTC工况计算结果 =====\n');
fprintf('滚动阻力 Ff = %.2f N\n',Ff);
fprintf('峰值电池功率：%.2f W\n',P_max);
fprintf('平均电池功率：%.2f W\n',P_avg);
fprintf('工况总能耗：%.3f kWh\n',E_total);
fprintf('工况总里程：%.3f km\n',dist_km);
fprintf('百公里电耗：%.2f kWh/100km\n',cons_100);
fprintf('理论续航里程：%.1f km\n',range_km);

% ========== 5 绘图：2行3列，6张子图 ==========
figure('Color','w');
subplot(2,3,1)
plot(t, v_kmh, 'b-','LineWidth',1.5);
xlabel('时间 t (s)'); ylabel('车速 (km/h)');
grid on; title('车速 v');

subplot(2,3,2)
plot(t, Fw, 'b-','LineWidth',1.5);
xlabel('时间 t (s)'); ylabel('空气阻力 (N)');
grid on; title('空气阻力 F_w');

subplot(2,3,3)
plot(t, Fi, 'k--','LineWidth',1.5);
xlabel('时间 t (s)'); ylabel('惯性阻力 (N)');
grid on; title('惯性阻力 F_i');

subplot(2,3,4)
plot(t, F_total, 'r-.','LineWidth',1.0); hold on;
idx1 = 1:30:length(t);
plot(t(idx1), F_total(idx1), 'ro','MarkerSize',3);
xlabel('时间 t (s)'); ylabel('总阻力 (N)');
grid on; title('总阻力 F_{total}'); hold off;

subplot(2,3,5)
plot(t, Pmech, 'k-','LineWidth',1.5);
xlabel('时间 t (s)'); ylabel('机械功率 (W)');
grid on; title('机械功率 P_{mech}');

subplot(2,3,6)
plot(t, Pbatt, 'm--','LineWidth',1.0); hold on;
idx2 = 1:50:length(t);
plot(t(idx2), Pbatt(idx2), 'm*','MarkerSize',3);
xlabel('时间 t (s)'); ylabel('电池功率 (W)');
grid on; title('电池功率 P_{batt}'); hold off;

% 累计能耗与SOC曲线（报告要求图）
figure('Color','w');
subplot(2,1,1); plot(t, E_cum_kWh, 'b-','LineWidth',1.5); grid on;
xlabel('时间 t (s)'); ylabel('累计能耗 (kWh)'); title('CLTC工况累计能耗曲线');
subplot(2,1,2); plot(t, SOC, 'r-','LineWidth',1.5); grid on;
xlabel('时间 t (s)'); ylabel('SOC'); title('CLTC工况电池SOC时序曲线');
