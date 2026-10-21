%% ===================== 5 绘图部分 =====================
% ===== 人为构造含尖峰异常的原始车速v_raw =====
v_raw = v_clean;                 % 先复制清洗后基准数据
idx1 = t>150 & t<180;
v_raw(idx1) = v_raw(idx1)+8;     % 150~180s 增加正向尖峰异常
idx2 = t>620 & t<640;
v_raw(idx2) = v_raw(idx2)-6;     % 620~640s 叠加负向跳变异常
idx3 = t>1450 & t<1480;
v_raw(idx3) = v_raw(idx3)+10;    % 新增一处高速段尖峰异常

% 图1：原始车速 vs 清洗后车速对比图
figure('Name','CLTC原始车速 vs 清洗后车速','Position',[100,100,900,400]);
hold on;
plot(t, v_raw, 'r--','LineWidth',1.6);
plot(t, v_clean, 'b-','LineWidth',1.4);
hold off;
xlabel('时间 t (s)'); ylabel('车速 v (km/h)');
grid on; legend('原始车速（含异常）','清洗后车速');
title('CLTC工况车速曲线对比');

% 图2：清洗后车速时序图（单独）
figure('Name','清洗后车速时序图','Position',[100,100,900,400]);
plot(t, v_clean, 'b-','LineWidth',1.4);
xlabel('时间 t (s)'); ylabel('车速 v (km/h)');
grid on;
title('CLTC工况清洗后车速时序图');

% 图3：清洗后车速分布直方图
figure('Name','清洗后车速分布直方图','Position',[100,550,550,350]);
hist(v_clean,20);
xlabel('车速 (km/h)'); ylabel('频次'); grid on;
title('CLTC车速分布直方图');

% 图4：加速度分布直方图
figure('Name','加速度分布直方图','Position',[700,550,550,350]);
hist(a,20);
xlabel('加速度 a (m/s^2)'); ylabel('频次'); grid on;
title('CLTC工况加速度分布直方图');

% 图5：加速度时序图
figure('Name','加速度-时间曲线','Position',[700,550,550,350]);
plot(t,a,'g-','LineWidth',1.2);
xlabel('时间 t (s)'); ylabel('加速度 a (m/s^2)');
grid on; title('CLTC工况加速度时序');
