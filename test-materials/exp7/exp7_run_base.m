%% Exp7 三组对比仿真脚本
% 基准工况
CN=50; R0pkg=0.02*96; m_pkg=1500; Ff_pkg=1500*9.81*0.015;
sim('Exp7_Rint_Battery');
sim_time_base=soc_result_time; soc_base=soc_result; mileage_base=mileage;
E_base=trapz(soc_result_time,Pbatt_demand)/(3.6e6);
save('exp7_base.mat','sim_time_base','soc_base','mileage_base','E_base');
