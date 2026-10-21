
% ========== 5 绘图 ==========
figure('Color','w');
subplot(2,2,1); plot(m_list,E_m,'b-','LineWidth',1.5); grid on;
xlabel('整车质量 (kg)'); ylabel('工况能耗 (kWh)'); title('质量-能耗');
subplot(2,2,2); plot(Cd_list,E_c,'r-','LineWidth',1.5); grid on;
xlabel('风阻系数 Cd'); ylabel('工况能耗 (kWh)'); title('风阻-能耗');
subplot(2,2,3); plot(f_list,E_f,'k-','LineWidth',1.5); grid on;
xlabel('滚动阻力系数 f'); ylabel('工况能耗 (kWh)'); title('滚阻-能耗');
subplot(2,2,4); plot(eta_list,E_e,'m-','LineWidth',1.5); grid on;
xlabel('电机效率 \eta_m'); ylabel('工况能耗 (kWh)'); title('效率-能耗');
print('-dpng','-r110','fig8_1_sens.png');

% 相关性热力图（用彩色网格近似 heatmap）
figure('Color','w');
imagesc(R); colorbar; axis square;
set(gca,'XTick',1:5,'XTickLabel',labels,'YTick',1:5,'YTickLabel',labels);
title('能耗因子相关系数矩阵');
for i=1:5
    for j=1:5
        text(j,i,num2str(R(i,j),'%.2f'),'HorizontalAlignment','center','Color','w','FontWeight','bold');
    end
end
print('-dpng','-r110','fig8_2_corr.png');

% exp6 Simulink 与 exp5 脚本对比柱状图
figure('Color','w');
bar([E_th5 E_sim7_base]);
set(gca,'XTickLabel',{'理论计算(脚本)','Rint仿真(Exp7)'});
ylabel('CLTC工况能耗 (kWh)'); title('理论计算 vs Rint电池仿真能耗对比'); grid on;
print('-dpng','-r110','fig8_3_err.png');
close all;
disp('实验8完成');
