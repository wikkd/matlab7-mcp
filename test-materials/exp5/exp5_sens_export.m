
% ========== 6 参数敏感性对比：整车质量、风阻系数 ==========
% 质量对比 1200/1500/1800 kg
m_list = [1200 1500 1800];
E_m = zeros(1,3); R_m = zeros(1,3);
for k = 1:3
    mk = m_list(k);
    Ffk = mk*g*f;
    Fik = mk*a;
    Ftk = Ffk + Fw + Fik;
    Pk = Ftk .* v_ms; Pk(Pk<0) = 0;
    Pbk = Pk / eta_m;
    Ek = trapz(t, Pbk)/(3600*1000);
    E_m(k) = Ek;
    R_m(k) = Ebat / (Ek/dist_km*100) * 100;
end

% 风阻系数对比 0.26/0.32/0.40
Cd_list = [0.26 0.32 0.40];
E_c = zeros(1,3); R_c = zeros(1,3);
for k = 1:3
    Cdk = Cd_list(k);
    Fwk = 0.5*rho*Cdk*A*v_ms.^2;
    Ftk2 = Ff + Fwk + Fi;
    Pk2 = Ftk2 .* v_ms; Pk2(Pk2<0) = 0;
    Pbk2 = Pk2 / eta_m;
    Ek2 = trapz(t, Pbk2)/(3600*1000);
    E_c(k) = Ek2;
    R_c(k) = Ebat / (Ek2/dist_km*100) * 100;
end

figure('Color','w');
subplot(2,2,1);
bar(E_m); set(gca,'XTickLabel',{'1200kg','1500kg','1800kg'}); grid on;
ylabel('工况能耗 (kWh)'); title('整车质量对能耗的影响');
subplot(2,2,2);
bar(R_m); set(gca,'XTickLabel',{'1200kg','1500kg','1800kg'}); grid on;
ylabel('理论续航 (km)'); title('整车质量对续航的影响');
subplot(2,2,3);
bar(E_c); set(gca,'XTickLabel',{'Cd=0.26','Cd=0.32','Cd=0.40'}); grid on;
ylabel('工况能耗 (kWh)'); title('风阻系数对能耗的影响');
subplot(2,2,4);
bar(R_c); set(gca,'XTickLabel',{'Cd=0.26','Cd=0.32','Cd=0.40'}); grid on;
ylabel('理论续航 (km)'); title('风阻系数对续航的影响');

% ========== 7 导出计算结果，给后面子项目用 ==========
out_data = [t, v_kmh, v_ms, a, Fw, Fi, F_total, Pmech, Pbatt];
dlmwrite('CLTC_power_result.csv', out_data, 'delimiter', ',', 'precision', 6);
disp('数据导出完成！');
disp('计算结果保存到 CLTC_power_result.csv');
save exp5_result.mat t v_kmh v_ms a Fw Fi F_total Pmech Pbatt E_cum_kWh SOC E_total dist_km cons_100 range_km E_m R_m E_c R_c;
