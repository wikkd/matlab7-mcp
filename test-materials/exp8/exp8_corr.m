%% 实验8：能耗影响因素相关性及仿真误差分析
clear; clc; close all;

% ========== 1 读取实验4/5 时序数据 ==========
data = dlmread('..\exp5\CLTC_power_result.csv',',');
t=data(:,1); v_kmh=data(:,2); v_ms=data(:,3); a=data(:,4);
Fw=data(:,5); Fi=data(:,6); F_total=data(:,7); Pmech=data(:,8); Pbatt=data(:,9);

% ========== 2 逐时刻能耗因子 ==========
% 因子：车速、车速平方(风阻相关)、加速度、总阻力、机械功率
F1 = v_kmh;
F2 = v_ms.^2;
F3 = a;
F4 = F_total;
F5 = Pbatt;
M = [F1 F2 F3 F4 F5];

% 剔除全零功率段对相关的偏置（保留怠速以体现真实工况）
% 皮尔逊相关系数矩阵
n=size(M,1);
R=zeros(5,5);
for i=1:5
    for j=1:5
        xi=M(:,i); xj=M(:,j);
        R(i,j)=sum((xi-mean(xi)).*(xj-mean(xj)))/sqrt(sum((xi-mean(xi)).^2)*sum((xj-mean(xj)).^2));
    end
end
disp('===== 能耗因子皮尔逊相关系数矩阵 =====');
disp(R);
labels={'车速','车速^2','加速度','总阻力','电池功率'};
