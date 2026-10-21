%% 子项目1：CLTC工况数据读取、清洗、可视化【老旧MATLAB兼容版，无table函数】
clear; clc; close all;

%% ========== 1 自动生成CLTC-P工况数据 ==========
disp('自动生成CLTC-P工况数据...');
t = (0:1:1799)';
v_kmh = zeros(1800,1);

% 第一段：低速段 0~673 s
for i = 1:674
    tt = i-1;
    if tt<100
        v_kmh(i) = 30*sin(tt/40);
    elseif tt<300
        v_kmh(i) = 42*sin(tt/70 + 1);
    else
        v_kmh(i) = 48.1*sin(tt/120 + 2);
    end
end
v_kmh(v_kmh<0)=0;

% 第二段：中速段 674~1366 s
for i = 675:1367
    tt = i-1;
    v_kmh(i) = 71.2*sin(tt/160 + 0.5);
end
v_kmh(v_kmh<0)=0;

% 第三段：高速段 1367~1799 s
for i = 1368:1800
    tt = i-1;
    v_kmh(i) = 114*sin(tt/220 - 1.2);
end
v_kmh(v_kmh<0)=0;
v_kmh(v_kmh>114)=114;

% 拼接矩阵 [t, v_kmh]，dlmwrite导出csv（老版本支持）
data_cltc = [t, v_kmh];
dlmwrite('CLTC.csv',data_cltc,'delimiter',',','precision',6);
disp('CLTC.csv 已经生成完成！（老版本兼容，不带表头）');
