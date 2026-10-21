%% ===================== 6 导出清洗好的数据，给子项目2使用！ =====================
result_data = [t, v_clean, v_ms, a];
dlmwrite('CLTC_clean_data.csv',result_data,'delimiter',',','precision',6);
disp('清洗后数据已保存到 CLTC_clean_data.csv，供子项目2调用！');

%% ===================== 7 构造 simin，给子项目3使用！ =====================
data = csvread('CLTC_clean_data.csv');
t2 = data(:,1);
v2 = data(:,2);
simin = [t2, v2];
disp('simin 已构造，供子项目3 From Workspace 使用');
save exp4_workspace.mat t v_clean v_ms a simin;  % 保存工作区快照，便于复现
