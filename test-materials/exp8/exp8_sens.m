% ========== 3 参数扫描敏感性 ==========
m0=1500; g=9.81; f0=0.015; Cd0=0.32; A=2.2; rho=1.225; eta=0.9;
Ff0=m0*g*f0;
m_list=1200:100:2000;
Cd_list=0.24:0.02:0.44;
f_list=0.008:0.002:0.024;
eta_list=0.80:0.02:0.98;
E_m=zeros(size(m_list)); E_c=zeros(size(Cd_list)); E_f=zeros(size(f_list)); E_e=zeros(size(eta_list));
for k=1:numel(m_list)
    Ffk=m_list(k)*g*f0; Fik=m_list(k)*a;
    Pk=(Ffk+Fw+Fik).*v_ms; Pk(Pk<0)=0;
    E_m(k)=trapz(t,Pk/eta)/(3.6e6);
end
for k=1:numel(Cd_list)
    Fwk=0.5*rho*Cd_list(k)*A*v_ms.^2;
    Pk=(Ff0+Fwk+Fi).*v_ms; Pk(Pk<0)=0;
    E_c(k)=trapz(t,Pk/eta)/(3.6e6);
end
for k=1:numel(f_list)
    Ffk=m0*g*f_list(k); Fik=m0*a;
    Pk=(Ffk+Fw+Fik).*v_ms; Pk(Pk<0)=0;
    E_f(k)=trapz(t,Pk/eta)/(3.6e6);
end
for k=1:numel(eta_list)
    Pk=(Ff0+Fw+Fi).*v_ms; Pk(Pk<0)=0;
    E_e(k)=trapz(t,Pk/eta_list(k))/(3.6e6);
end
% 敏感度 S=(dE/E)/(dx/x)
k2=round(numel(m_list)/2);
S_m=(E_m(end)-E_m(1))/E_m(k2)/((m_list(end)-m_list(1))/m_list(k2));
k2=round(numel(Cd_list)/2);
S_c=(E_c(end)-E_c(1))/E_c(k2)/((Cd_list(end)-Cd_list(1))/Cd_list(k2));
k2=round(numel(f_list)/2);
S_f=(E_f(end)-E_f(1))/E_f(k2)/((f_list(end)-f_list(1))/f_list(k2));
k2=round(numel(eta_list)/2);
S_e=(E_e(end)-E_e(1))/E_e(k2)/((eta_list(end)-eta_list(1))/eta_list(k2));
fprintf('Sensitivity: m=%.3f Cd=%.3f f=%.3f eta=%.3f\n',S_m,S_c,S_f,S_e);
save exp8_sens_data.mat m_list Cd_list f_list eta_list E_m E_c E_f E_e S_m S_c S_f S_e;
