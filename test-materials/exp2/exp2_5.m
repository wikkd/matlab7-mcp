% 实验2 任务5：符号变量声明与表达式化简
clear; clc; close all;
% 声明符号变量x
syms x;
% 构建两个符号表达式
f = x^3 + sin(x) + 3;       % 表达式f
g = x^2 - cos(x) + 5;       % 表达式g
% 计算和、差、积并化简
sum_fg = simplify(f + g);   % 求和并化简
diff_fg = simplify(f - g);  % 求差并化简
prod_fg = simplify(f * g);  % 求积并化简
% 显示结果
disp('f + g 化简结果:'); disp(sum_fg);
disp('f - g 化简结果:'); disp(diff_fg);
disp('f * g 化简结果:'); disp(prod_fg);

% 绘图代码（区分颜色+线型，适配MATLAB7.0 ezplot）
figure;
h1 = ezplot(f,[-2,2]);
set(h1,'Color','r','LineStyle','-','LineWidth',1.5);  % f(x)：红色实线
hold on;
h2 = ezplot(g,[-2,2]);
set(h2,'Color','b','LineStyle','--','LineWidth',1.5); % g(x)：蓝色虚线
title('符号函数 f(x) 与 g(x) 曲线');
legend('f(x)=x^3+sin(x)+3','g(x)=x^2-cos(x)+5');
grid on;
hold off;
