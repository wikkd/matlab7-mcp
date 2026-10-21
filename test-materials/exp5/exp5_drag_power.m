%% 子项目2：基于CLTC工况计算行驶阻力、功率、能耗 【超老MATLAB兼容版】
clear; clc; close all;

% ========== 1 读取子项目1输出的清洗后数据 ==========
data = dlmread('..\exp4\CLTC_clean_data.csv',',');
t       = data(:,1);    % 时间 s
v_kmh   = data(:,2);    % 车速 km/h
v_ms    = data(:,3);    % 车速 m/s
a_raw   = data(:,4);    % 原始加速度 m/s^2

% ========== 加速度限幅，切掉过大的加减速尖峰 ==========
a = a_raw;
a(a > 2)  = 2;     % 限制最大正向加速度 2 m/s^2
a(a < -3) = -3;    % 限制最大减速度 -3 m/s^2

% ========== 2 车辆基础参数（乘用车，课程设计常用） ==========
m = 1500;        % 整车质量 kg
g = 9.81;        % 重力加速度
f = 0.015;       % 滚动阻力系数
Cd = 0.32;       % 风阻系数
A = 2.2;         % 迎风面积 m^2
rho = 1.225;     % 空气密度 kg/m3
eta_m = 0.9;     % 电机效率
Ebat = 50;       % 电池额定容量 kWh（用于SOC计算）

% ========== 3 各项阻力计算 ==========
Ff = m * g * f;                    % 滚动阻力（近似恒定）
Fw = 0.5 * rho * Cd * A * v_ms.^2; % 空气阻力
Fi = m * a;                        % 加速惯性力（坡度=0）
F_total = Ff + Fw + Fi;            % 总需求力

% 功率：力 × 速度；电机只输出正功率，滑行制动时不输出
Pmech = F_total .* v_ms;           % 车轮端机械功率
P = Pmech;
P(P<0) = 0;                        % 驱动功率截断
Pbatt = P / eta_m;                 % 电池侧输出功率（考虑电机效率）

% ========== 4 统计结果【能耗单位换算 J -> kWh】 ==========
P_max = max(Pbatt);
P_avg = mean(Pbatt);
E_total = trapz(t, Pbatt) / (3600 * 1000);   % 工况总能耗 kWh

% 累计能耗与时序SOC（初始满电，容量50kWh）
E_cum = cumsum(Pbatt) * 1;                  % 粗略累加(J)
E_cum = cumsum(Pbatt(:).* [1; diff(t(:))]); % 按时间步长加权 精确
E_cum_kWh = E_cum / 3.6e6;
SOC = 1 - E_cum_kWh / Ebat;
