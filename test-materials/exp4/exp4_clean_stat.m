%% ===================== 2 数据清洗：剔除异常值 =====================
v_raw = v_kmh;
idx_bad = (v_kmh < 0) | (v_kmh > 140);
v_kmh(idx_bad) = NaN;
% fillmissing 老版本没有！用循环相邻两点均值替换 NaN
v_clean = v_kmh;
for ii = 2:length(v_clean)-1
    if isnan(v_clean(ii))
        v_clean(ii) = (v_clean(ii-1)+v_clean(ii+1))/2;
    end
end
v_ms = v_clean / 3.6;

%% ===================== 3 计算加速度（差分） =====================
dt = mean(diff(t));
a = diff(v_ms)./diff(t);
a = [a; a(end)];

%% ===================== 4 描述性统计 =====================
v_mean = mean(v_clean);
v_max  = max(v_clean);
v_std  = std(v_clean);
total_time = max(t);
distance_km = trapz(t, v_clean)/3600;
% 怠速时长占比（车速为0的样本比例）
idle_ratio = sum(v_clean==0)/length(v_clean);
idle_time = sum(v_clean==0);

fprintf('\n===== CLTC工况统计结果 =====\n');
fprintf('平均车速：%.2f km/h\n',v_mean);
fprintf('最高车速：%.2f km/h\n',v_max);
fprintf('车速标准差：%.2f km/h\n',v_std);
fprintf('总时长：%.0f s\n',total_time);
fprintf('工况总里程：%.3f km\n',distance_km);
fprintf('怠速时长：%.0f s，占比：%.1f%%\n',idle_time, idle_ratio*100);
