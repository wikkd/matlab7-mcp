% 实验2 任务7：符号法求解线性方程组
clear; clc; close all;
syms x y z
% 旧版solve：写表达式（等式移项等于0，不要用==）
eq1 = x + y + z - 6;
eq2 = 2*x - y + z - 3;
eq3 = x + 2*y - z - 2;
% solve符号函数求解方程组
res = solve(eq1, eq2, eq3, x, y, z);
% 取出解，转为符号数组
X = [res.x; res.y; res.z];
% 显示求解结果
disp('solve符号函数求解结果');
disp(['x = ', char(X(1))]);
disp(['y = ', char(X(2))]);
disp(['z = ', char(X(3))]);
