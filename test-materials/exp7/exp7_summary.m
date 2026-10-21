% Exp7 ½á¹û»ã×Ü
Ebat=50; Lcyc=9.731;
E_per_km_base=E_base/Lcyc; E_per_km_load=E_load/Lcyc; E_per_km_cold=E_cold/Lcyc;
r_base=0.75*Ebat/E_per_km_base; r_load=0.75*Ebat/E_per_km_load; r_cold=0.75*Ebat/E_per_km_cold;
fprintf('===== Exp7 =====\n');
fprintf('base: E=%.3f kWh, e=%.3f kWh/km, SOC_end=%.3f, range=%.1f km\n',E_base,E_per_km_base,sb(end),r_base);
fprintf('load: E=%.3f kWh, e=%.3f kWh/km, SOC_end=%.3f, range=%.1f km\n',E_load,E_per_km_load,sl(end),r_load);
fprintf('cold: E=%.3f kWh, e=%.3f kWh/km, SOC_end=%.3f, range=%.1f km\n',E_cold,E_per_km_cold,sc(end),r_cold);
