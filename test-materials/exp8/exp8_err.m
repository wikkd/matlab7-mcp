% ========== 4 仿真误差分析 ==========
% 4.1 Simulink(exp6) vs 脚本(exp5)：由实验6结果直接给出
rmse_Fw=0.0002; rmse_Fi=211.0; rmse_Pm=1108.7; rmse_Pb=894.9;
fprintf('Simulink vs RMSE: Fw=%.4f N, Fi=%.1f N, Pmech=%.1f W, Pbatt=%.1f W\n',rmse_Fw,rmse_Fi,rmse_Pm,rmse_Pb);
% 4.2 Rint(exp7) vs exp5
E_sim7_base=1.096;
E_th5=1.090;
err_pct=(E_sim7_base-E_th5)/E_th5*100;
fprintf('Rint vs theory: sim=%.3f kWh, th=%.3f kWh, dev=%.2f %%\n',E_sim7_base,E_th5,err_pct);
