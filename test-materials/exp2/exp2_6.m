% 实验2 任务6：符号微积分推导
clear; clc; close all;
syms x;                     % 声明符号变量
% 构建符号表达式
f = x^3 + sin(x) + 3;
% 对表达式f求一阶导数
df = diff(f, x);            % 对x求一阶导数
% 对表达式f求不定积分
int_f = int(f, x);          % 对x求不定积分
% 以标准数学排版格式显示结果
disp('f 的一阶导数：');
pretty(df);                 % pretty函数输出数学排版格式
disp('f 的不定积分：');
pretty(int_f);

% 绘图代码，MATLAB7.0使用ezplot，区分颜色线型
figure;
h1 = ezplot(f,[-2,2]);
set(h1,'Color','r','LineStyle','-','LineWidth',1.5);  % 原函数：红色实线
hold on;
h2 = ezplot(df,[-2,2]);
set(h2,'Color','g','LineStyle','--','LineWidth',1.5); % 导函数：绿色虚线
h3 = ezplot(int_f,[-2,2]);
set(h3,'Color','b','LineStyle',':','LineWidth',1.5);  % 积分函数：蓝色点线
title('原函数、一阶导函数、不定积分函数曲线');
legend('原函数 f(x)','一阶导数 df(x)','不定积分 int\_f(x)');
grid on;
hold off;
