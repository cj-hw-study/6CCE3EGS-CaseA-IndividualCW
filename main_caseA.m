clear; clc; close all;

data = readtable('caseA_smart_home_30min_summer.csv');

disp(head(data));
disp(size(data));

dt = 0.5;
Emax = 5;
Pch_max = 2.5;
Pdis_max = 2.5;
eta_ch = 0.95;
eta_dis = 0.95;
SOC0 = 2.5;

disp('Parameters loaded successfully.');

% Extract data columns
N = height(data);
pv = data.pv_kw;
load_kw = data.base_load_kw;
import_tariff = data.import_tariff_gbp_per_kwh;
export_price = data.export_price_gbp_per_kwh;
time = data.timestamp;

% Preallocate arrays
SOC = zeros(N+1,1);
Pch = zeros(N,1);
Pdis = zeros(N,1);
Pimp = zeros(N,1);
Pexp = zeros(N,1);

SOC(1) = SOC0;

% Self-consumption dispatch
for t = 1:N
    pv_now = pv(t);
    load_now = load_kw(t);

    if pv_now >= load_now
        % PV covers load first
        surplus = pv_now - load_now;

        % Battery charging limit from power and remaining energy capacity
        charge_power_limit = min(Pch_max, (Emax - SOC(t)) / (eta_ch * dt));
        Pch(t) = min(surplus, max(charge_power_limit, 0));

        % Remaining surplus exported to grid
        Pexp(t) = surplus - Pch(t);

        % No import or discharge needed
        Pdis(t) = 0;
        Pimp(t) = 0;

    else
        % PV insufficient, battery discharges first
        deficit = load_now - pv_now;

        discharge_power_limit = min(Pdis_max, SOC(t) * eta_dis / dt);
        Pdis(t) = min(deficit, max(discharge_power_limit, 0));

        % Remaining deficit imported from grid
        Pimp(t) = deficit - Pdis(t);

        % No charging or export
        Pch(t) = 0;
        Pexp(t) = 0;
    end

    % Update SOC
    SOC(t+1) = SOC(t) + eta_ch * Pch(t) * dt - (Pdis(t) * dt / eta_dis);
end

% Calculate energy values (kWh)
E_import = sum(Pimp) * dt;
E_export = sum(Pexp) * dt;
E_charge = sum(Pch) * dt;
E_discharge = sum(Pdis) * dt;

% Calculate electricity cost (£)
cost_import = sum(Pimp .* import_tariff) * dt;
revenue_export = sum(Pexp .* export_price) * dt;
net_cost = cost_import - revenue_export;

% Display summary
fprintf('\n--- Policy 1: Self-consumption summary ---\n');
fprintf('Total grid import: %.2f kWh\n', E_import);
fprintf('Total grid export: %.2f kWh\n', E_export);
fprintf('Total battery charge: %.2f kWh\n', E_charge);
fprintf('Total battery discharge: %.2f kWh\n', E_discharge);
fprintf('Import cost: £%.2f\n', cost_import);
fprintf('Export revenue: £%.2f\n', revenue_export);
fprintf('Net cost: £%.2f\n', net_cost);
fprintf('Initial SOC: %.2f kWh\n', SOC(1));
fprintf('Final SOC: %.2f kWh\n', SOC(end));

% Plot PV and load
figure;
plot(time, pv, 'LineWidth', 1.2);
hold on;
plot(time, load_kw, 'LineWidth', 1.2);
grid on;
xlabel('Time');
ylabel('Power (kW)');
title('PV Generation and Household Load');
legend('PV', 'Load');

% Plot SOC
figure;
plot(time, SOC(1:end-1), 'LineWidth', 1.5);
grid on;
xlabel('Time');
ylabel('SOC (kWh)');
title('Battery SOC - Policy 1 Self-consumption');

%% Verification checks

% 1. Energy balance error at each timestep
balance_error = pv + Pimp + Pdis - load_kw - Pch - Pexp;

max_balance_error = max(abs(balance_error));
mean_balance_error = mean(abs(balance_error));

% 2. SOC bounds check
soc_min = min(SOC);
soc_max = max(SOC);
soc_within_bounds = all(SOC >= -1e-9) && all(SOC <= Emax + 1e-9);

% 3. Charge/discharge power limit checks
charge_limit_ok = all(Pch >= -1e-9) && all(Pch <= Pch_max + 1e-9);
discharge_limit_ok = all(Pdis >= -1e-9) && all(Pdis <= Pdis_max + 1e-9);

% 4. Grid import/export non-negative
import_ok = all(Pimp >= -1e-9);
export_ok = all(Pexp >= -1e-9);

% 5. End-of-horizon SOC check
end_soc_ok = SOC(end) >= SOC0;

% Display verification summary
fprintf('\n--- Verification summary ---\n');
fprintf('Max energy balance error: %.6e kW\n', max_balance_error);
fprintf('Mean energy balance error: %.6e kW\n', mean_balance_error);
fprintf('SOC min: %.2f kWh\n', soc_min);
fprintf('SOC max: %.2f kWh\n', soc_max);
fprintf('SOC within bounds: %d\n', soc_within_bounds);
fprintf('Charge power within limit: %d\n', charge_limit_ok);
fprintf('Discharge power within limit: %d\n', discharge_limit_ok);
fprintf('Grid import non-negative: %d\n', import_ok);
fprintf('Grid export non-negative: %d\n', export_ok);
fprintf('Final SOC >= Initial SOC: %d\n', end_soc_ok);

%% Policy 2: Tariff-aware dispatch

price_threshold = median(import_tariff);   % simple threshold
SOC_reserve = 1.0;                         % keep some reserve in battery

SOC2 = zeros(N+1,1);
Pch2 = zeros(N,1);
Pdis2 = zeros(N,1);
Pimp2 = zeros(N,1);
Pexp2 = zeros(N,1);

SOC2(1) = SOC0;

for t = 1:N
    pv_now = pv(t);
    load_now = load_kw(t);
    price_now = import_tariff(t);

    if pv_now >= load_now
        % PV covers load first
        surplus = pv_now - load_now;

        % Charge battery with surplus PV
        charge_power_limit = min(Pch_max, (Emax - SOC2(t)) / (eta_ch * dt));
        Pch2(t) = min(surplus, max(charge_power_limit, 0));

        % Remaining surplus exported
        Pexp2(t) = surplus - Pch2(t);

        Pdis2(t) = 0;
        Pimp2(t) = 0;

    else
        % PV is not enough
        deficit = load_now - pv_now;

        if price_now >= price_threshold
            % High price period: use battery, but keep reserve SOC
            available_energy = max(SOC2(t) - SOC_reserve, 0);
            discharge_power_limit = min(Pdis_max, available_energy * eta_dis / dt);
            Pdis2(t) = min(deficit, max(discharge_power_limit, 0));
        else
            % Low price period: keep battery for later
            Pdis2(t) = 0;
        end

        Pimp2(t) = deficit - Pdis2(t);
        Pch2(t) = 0;
        Pexp2(t) = 0;
    end

    % Update SOC
    SOC2(t+1) = SOC2(t) + eta_ch * Pch2(t) * dt - (Pdis2(t) * dt / eta_dis);
end

% Energy summary
E_import2 = sum(Pimp2) * dt;
E_export2 = sum(Pexp2) * dt;
E_charge2 = sum(Pch2) * dt;
E_discharge2 = sum(Pdis2) * dt;

% Cost summary
cost_import2 = sum(Pimp2 .* import_tariff) * dt;
revenue_export2 = sum(Pexp2 .* export_price) * dt;
net_cost2 = cost_import2 - revenue_export2;

fprintf('\n--- Policy 2: Tariff-aware summary ---\n');
fprintf('Price threshold: %.4f GBP/kWh\n', price_threshold);
fprintf('SOC reserve: %.2f kWh\n', SOC_reserve);
fprintf('Total grid import: %.2f kWh\n', E_import2);
fprintf('Total grid export: %.2f kWh\n', E_export2);
fprintf('Total battery charge: %.2f kWh\n', E_charge2);
fprintf('Total battery discharge: %.2f kWh\n', E_discharge2);
fprintf('Import cost: £%.2f\n', cost_import2);
fprintf('Export revenue: £%.2f\n', revenue_export2);
fprintf('Net cost: £%.2f\n', net_cost2);
fprintf('Initial SOC: %.2f kWh\n', SOC2(1));
fprintf('Final SOC: %.2f kWh\n', SOC2(end));

%% Verification for Policy 2

balance_error2 = pv + Pimp2 + Pdis2 - load_kw - Pch2 - Pexp2;

max_balance_error2 = max(abs(balance_error2));
mean_balance_error2 = mean(abs(balance_error2));

soc_min2 = min(SOC2);
soc_max2 = max(SOC2);
soc_within_bounds2 = all(SOC2 >= -1e-9) && all(SOC2 <= Emax + 1e-9);

charge_limit_ok2 = all(Pch2 >= -1e-9) && all(Pch2 <= Pch_max + 1e-9);
discharge_limit_ok2 = all(Pdis2 >= -1e-9) && all(Pdis2 <= Pdis_max + 1e-9);

import_ok2 = all(Pimp2 >= -1e-9);
export_ok2 = all(Pexp2 >= -1e-9);

end_soc_ok2 = SOC2(end) >= SOC0;

fprintf('\n--- Verification summary for Policy 2 ---\n');
fprintf('Max energy balance error: %.6e kW\n', max_balance_error2);
fprintf('Mean energy balance error: %.6e kW\n', mean_balance_error2);
fprintf('SOC min: %.2f kWh\n', soc_min2);
fprintf('SOC max: %.2f kWh\n', soc_max2);
fprintf('SOC within bounds: %d\n', soc_within_bounds2);
fprintf('Charge power within limit: %d\n', charge_limit_ok2);
fprintf('Discharge power within limit: %d\n', discharge_limit_ok2);
fprintf('Grid import non-negative: %d\n', import_ok2);
fprintf('Grid export non-negative: %d\n', export_ok2);
fprintf('Final SOC >= Initial SOC: %d\n', end_soc_ok2);

%% Comparison plots

% SOC comparison
figure;
plot(time, SOC(1:end-1), 'LineWidth', 1.2);
hold on;
plot(time, SOC2(1:end-1), 'LineWidth', 1.2);
grid on;
xlabel('Time');
ylabel('SOC (kWh)');
title('SOC Comparison: Policy 1 vs Policy 2');
legend('Policy 1: Self-consumption', 'Policy 2: Tariff-aware');

% Net cost comparison
figure;
bar([net_cost, net_cost2]);
grid on;
ylabel('Net Cost (£)');
title('Net Cost Comparison');
set(gca, 'XTickLabel', {'Policy 1', 'Policy 2'});

%% Results comparison table

Policy = ["Policy 1"; "Policy 2"];
GridImport_kWh = [E_import; E_import2];
GridExport_kWh = [E_export; E_export2];
BatteryCharge_kWh = [E_charge; E_charge2];
BatteryDischarge_kWh = [E_discharge; E_discharge2];
ImportCost_GBP = [cost_import; cost_import2];
ExportRevenue_GBP = [revenue_export; revenue_export2];
NetCost_GBP = [net_cost; net_cost2];
InitialSOC_kWh = [SOC(1); SOC2(1)];
FinalSOC_kWh = [SOC(end); SOC2(end)];

results_table = table(Policy, GridImport_kWh, GridExport_kWh, ...
    BatteryCharge_kWh, BatteryDischarge_kWh, ...
    ImportCost_GBP, ExportRevenue_GBP, NetCost_GBP, ...
    InitialSOC_kWh, FinalSOC_kWh);

disp(results_table)

%% Save figures

saveas(1, 'Figure1_PV_Load.png');
saveas(2, 'Figure2_SOC_Policy1.png');
saveas(3, 'Figure3_SOC_Comparison.png');
saveas(4, 'Figure4_NetCost_Comparison.png');

writetable(results_table, 'results_comparison_caseA.csv');

%% Extension: Battery degradation

k_deg = 0.02;   % GBP per kWh throughput

% Throughput for both policies
throughput1 = E_charge + E_discharge;
throughput2 = E_charge2 + E_discharge2;

% Degradation cost
deg_cost1 = k_deg * throughput1;
deg_cost2 = k_deg * throughput2;

% Total cost including degradation
total_cost1_ext = net_cost + deg_cost1;
total_cost2_ext = net_cost2 + deg_cost2;

fprintf('\n--- Extension: Battery degradation ---\n');
fprintf('Degradation coefficient: %.3f GBP/kWh throughput\n', k_deg);

fprintf('\nPolicy 1:\n');
fprintf('Battery throughput: %.2f kWh\n', throughput1);
fprintf('Degradation cost: £%.2f\n', deg_cost1);
fprintf('Total cost including degradation: £%.2f\n', total_cost1_ext);

fprintf('\nPolicy 2:\n');
fprintf('Battery throughput: %.2f kWh\n', throughput2);
fprintf('Degradation cost: £%.2f\n', deg_cost2);
fprintf('Total cost including degradation: £%.2f\n', total_cost2_ext);

%% Extension plot: total cost including degradation

figure;
bar([total_cost1_ext, total_cost2_ext]);
grid on;
ylabel('Total Cost with Degradation (£)');
title('Total Cost Comparison Including Battery Degradation');
set(gca, 'XTickLabel', {'Policy 1', 'Policy 2'});

saveas(gcf, 'Figure5_TotalCost_WithDegradation.png');

%% Extension results table

Policy_ext = ["Policy 1"; "Policy 2"];
Throughput_kWh = [throughput1; throughput2];
DegradationCost_GBP = [deg_cost1; deg_cost2];
TotalCostWithDegradation_GBP = [total_cost1_ext; total_cost2_ext];

extension_table = table(Policy_ext, Throughput_kWh, ...
    DegradationCost_GBP, TotalCostWithDegradation_GBP);

disp(extension_table)

writetable(extension_table, 'extension_battery_degradation.csv');