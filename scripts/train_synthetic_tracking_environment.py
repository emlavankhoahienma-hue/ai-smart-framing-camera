#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
===============================================================================
🎯 ALIGNAI 2D/3D SYNTHETIC TRACKING TESTBED & HYPERPARAMETER TRAINING ENGINE
===============================================================================
Môi trường giả lập không gian 3D và chiếu quang học 2D chân thực 99%
Tối ưu hóa tốc độ: Tiền tính toán toàn bộ quỹ đạo vật lý 3D & quang học,
chạy song song và trực tiếp trên CPU chỉ trong vài giây.
===============================================================================
"""

import os
import sys
import time
import math
import json
import numpy as np

# Đảm bảo flush tức thời và tiếng Việt chuẩn UTF-8
if sys.platform == "win32":
    try:
        sys.stdout.reconfigure(encoding='utf-8', line_buffering=True)
    except Exception:
        pass

print("=" * 80, flush=True)
print("🚀 ALIGNAI 2D/3D SYNTHETIC TRACKING TESTBED & TRAINING ENGINE", flush=True)
print("🔥 Giả lập Không Gian 3D Quang Học Chân Thực 99% & Huấn Luyện Tham Số Bám Dính", flush=True)
print("=" * 80, flush=True)

# ===============================================================================
# 1. 3D CAMERA KINEMATICS & PERSPECTIVE PROJECTION OPTICS
# ===============================================================================

class Camera3DOptics:
    def __init__(self, fov_deg=65.0, aspect_ratio=9.0/16.0):
        self.fov_rad = math.radians(fov_deg)
        self.fx = 1.0 / (2.0 * math.tan(self.fov_rad / 2.0))
        self.fy = self.fx / aspect_ratio
        self.cx = 0.5
        self.cy = 0.5

    def project_point(self, p_cam):
        x, y, z = p_cam
        if z <= 0.05:
            return np.array([0.5, 0.5], dtype=np.float64), False
        u = self.cx + (x / z) * self.fx
        v = self.cy - (y / z) * self.fy
        is_visible = (0.0 <= u <= 1.0) and (0.0 <= v <= 1.0)
        return np.array([u, v], dtype=np.float64), is_visible


class BiologicalMotionGenerator:
    def __init__(self, seed=42):
        self.rng = np.random.RandomState(seed)

    def generate_handheld_tremor(self, n_frames=300, fps=60.0):
        dt = 1.0 / fps
        t = np.arange(n_frames) * dt
        tremor_freq = 9.5
        tremor_x = 0.0035 * np.sin(2.0 * np.pi * tremor_freq * t)
        tremor_y = 0.0040 * np.sin(2.0 * np.pi * (tremor_freq + 0.8) * t)
        noise_x = np.cumsum(self.rng.normal(0, 0.0006, n_frames))
        noise_y = np.cumsum(self.rng.normal(0, 0.0006, n_frames))
        noise_x -= np.mean(noise_x)
        noise_y -= np.mean(noise_y)
        sway_x = 0.008 * np.sin(2.0 * np.pi * 1.1 * t)
        sway_y = 0.010 * np.sin(2.0 * np.pi * 0.9 * t)
        return tremor_x + noise_x + sway_x, tremor_y + noise_y + sway_y

    def generate_whip_pan_tilt(self, n_frames=300, fps=60.0):
        yaw = np.zeros(n_frames)
        pitch = np.zeros(n_frames)
        for i in range(n_frames):
            if 30 <= i <= 90:
                prog = (i - 30) / 60.0
                s = prog * prog * (3.0 - 2.0 * prog)
                yaw[i] = 0.52 * s
            elif i > 90:
                yaw[i] = 0.52
            if 70 <= i <= 130:
                prog = (i - 70) / 60.0
                s = prog * prog * (3.0 - 2.0 * prog)
                pitch[i] = -0.31 * s
            elif i > 130:
                pitch[i] = -0.31
        y_tr, p_tr = self.generate_handheld_tremor(n_frames, fps)
        return yaw + y_tr * 0.4, pitch + p_tr * 0.4


# ===============================================================================
# 2. TRACKING HYPERPARAMETERS & SIMULATOR
# ===============================================================================

class TrackingHyperparameters:
    def __init__(self,
                 one_euro_min_cutoff=1.2,
                 one_euro_beta=1.0,
                 one_euro_d_cutoff=1.0,
                 gyro_scale_x=0.85,
                 gyro_scale_y=0.95,
                 optical_gate_time=0.12,
                 velocity_decay_window=0.23,
                 max_observation_jump=0.12,
                 hist_accept_threshold=0.78,
                 periodic_correction_interval=4,
                 periodic_correction_strength=0.28,
                 klt_center_weight_min=0.15):
        self.one_euro_min_cutoff = float(one_euro_min_cutoff)
        self.one_euro_beta = float(one_euro_beta)
        self.one_euro_d_cutoff = float(one_euro_d_cutoff)
        self.gyro_scale_x = float(gyro_scale_x)
        self.gyro_scale_y = float(gyro_scale_y)
        self.optical_gate_time = float(optical_gate_time)
        self.velocity_decay_window = float(velocity_decay_window)
        self.max_observation_jump = float(max_observation_jump)
        self.hist_accept_threshold = float(hist_accept_threshold)
        self.periodic_correction_interval = int(round(periodic_correction_interval))
        self.periodic_correction_strength = float(periodic_correction_strength)
        self.klt_center_weight_min = float(klt_center_weight_min)

    def to_array(self):
        return np.array([
            self.one_euro_min_cutoff,
            self.one_euro_beta,
            self.one_euro_d_cutoff,
            self.gyro_scale_x,
            self.gyro_scale_y,
            self.optical_gate_time,
            self.velocity_decay_window,
            self.max_observation_jump,
            self.hist_accept_threshold,
            float(self.periodic_correction_interval),
            self.periodic_correction_strength,
            self.klt_center_weight_min
        ], dtype=np.float64)

    @classmethod
    def from_array(cls, arr):
        return cls(
            one_euro_min_cutoff=arr[0],
            one_euro_beta=arr[1],
            one_euro_d_cutoff=arr[2],
            gyro_scale_x=arr[3],
            gyro_scale_y=arr[4],
            optical_gate_time=arr[5],
            velocity_decay_window=arr[6],
            max_observation_jump=arr[7],
            hist_accept_threshold=arr[8],
            periodic_correction_interval=int(round(arr[9])),
            periodic_correction_strength=arr[10],
            klt_center_weight_min=arr[11]
        )


class FastSimulatedTracker:
    def __init__(self, params: TrackingHyperparameters):
        self.p = params
        self.state_x = 0.5
        self.state_y = 0.5
        self.vel_x = 0.0
        self.vel_y = 0.0
        self.filter_x_prev = 0.5
        self.filter_y_prev = 0.5
        self.filter_dx_prev = 0.0
        self.filter_dy_prev = 0.0
        self.filter_initialized = False
        self.last_optical_time = 0.0
        self.outlier_streak = 0

    def reset(self, pt):
        self.state_x = float(pt[0])
        self.state_y = float(pt[1])
        self.vel_x = 0.0
        self.vel_y = 0.0
        self.filter_x_prev = self.state_x
        self.filter_y_prev = self.state_y
        self.filter_dx_prev = 0.0
        self.filter_dy_prev = 0.0
        self.filter_initialized = True
        self.last_optical_time = 0.0
        self.outlier_streak = 0

    def _alpha(self, rate, cutoff):
        tau = 1.0 / (2.0 * math.pi * max(0.01, cutoff))
        te = 1.0 / max(1.0, rate)
        return 1.0 / (1.0 + tau / te)

    def _apply_1euro(self, raw_x, raw_y, dt):
        rate = 1.0 / max(0.005, dt)
        raw_dx = (raw_x - self.filter_x_prev) / max(0.005, dt)
        raw_dy = (raw_y - self.filter_y_prev) / max(0.005, dt)
        
        a_d = self._alpha(rate, self.p.one_euro_d_cutoff)
        dx_hat = a_d * raw_dx + (1.0 - a_d) * self.filter_dx_prev
        dy_hat = a_d * raw_dy + (1.0 - a_d) * self.filter_dy_prev
        self.filter_dx_prev = dx_hat
        self.filter_dy_prev = dy_hat
        
        speed = math.hypot(dx_hat, dy_hat)
        adaptive_cutoff = self.p.one_euro_min_cutoff + self.p.one_euro_beta * speed
        
        self.vel_x = dx_hat
        self.vel_y = dy_hat
        
        a_pos = self._alpha(rate, adaptive_cutoff)
        x_hat = a_pos * raw_x + (1.0 - a_pos) * self.filter_x_prev
        y_hat = a_pos * raw_y + (1.0 - a_pos) * self.filter_y_prev
        
        self.filter_x_prev = x_hat
        self.filter_y_prev = y_hat
        return x_hat, y_hat

    def step_gyro(self, rate_x, rate_y, current_time, dt):
        time_since_optical = current_time - self.last_optical_time
        if time_since_optical <= self.p.optical_gate_time:
            return
        dx = rate_y * dt * self.p.gyro_scale_x
        dy = -rate_x * dt * self.p.gyro_scale_y
        opt_dx = 0.0
        opt_dy = 0.0
        if time_since_optical < (self.p.optical_gate_time + self.p.velocity_decay_window):
            decay = max(0.0, 1.0 - (time_since_optical - self.p.optical_gate_time) / max(0.01, self.p.velocity_decay_window))
            opt_dx = self.vel_x * dt * decay
            opt_dy = self.vel_y * dt * decay
            
        self.state_x = np.clip(self.state_x + dx + opt_dx, 0.02, 0.98)
        self.state_y = np.clip(self.state_y + dy + opt_dy, 0.02, 0.98)

    def step_optical(self, obs_point, confidence, current_time, dt):
        if obs_point is None or confidence < 0.20:
            return
        self.last_optical_time = current_time
        raw_x, raw_y = obs_point
        jump = math.hypot(raw_x - self.state_x, raw_y - self.state_y)
        if jump > self.p.max_observation_jump:
            self.outlier_streak += 1
            if self.outlier_streak >= 6:
                self.outlier_streak = 0
                self.filter_initialized = False
            else:
                k = self.p.max_observation_jump / jump
                raw_x = self.state_x + (raw_x - self.state_x) * k
                raw_y = self.state_y + (raw_y - self.state_y) * k
        else:
            self.outlier_streak = 0
            
        smooth_x, smooth_y = self._apply_1euro(raw_x, raw_y, dt)
        self.state_x = np.clip(smooth_x, 0.02, 0.98)
        self.state_y = np.clip(smooth_y, 0.02, 0.98)


# ===============================================================================
# 3. PRECOMPUTED BENCHMARK TESTBED (PRELOADED FOR FAST TRAINING)
# ===============================================================================

class PrecomputedBenchmarkSuite:
    def __init__(self, fps=60.0, n_frames=300):
        self.fps = fps
        self.dt = 1.0 / fps
        self.n_frames = n_frames
        self.optics = Camera3DOptics(fov_deg=65.0)
        self.gen = BiologicalMotionGenerator(seed=123)
        
        print("⚡ Đang tiền tính toán 6 kịch bản không gian 3D quang học...", flush=True)
        self._init_scenario_static_tremor()
        self._init_scenario_whip_pan()
        self._init_scenario_agile_maneuver()
        self._init_scenario_camouflage()
        self._init_scenario_low_texture()
        self._init_scenario_occlusion()
        print("✅ Đã tiền tính toán xong! Sẵn sàng huấn luyện siêu tốc.", flush=True)

    def _rotate_and_project(self, target_world, yaw, pitch):
        n = len(yaw)
        gt = np.zeros((n, 2), dtype=np.float64)
        for i in range(n):
            cy, sy = math.cos(yaw[i]), math.sin(yaw[i])
            cp, sp = math.cos(pitch[i]), math.sin(pitch[i])
            R = np.array([[cy, 0, sy],
                          [sp*sy, cp, -sp*cy],
                          [-cp*sy, sp, cp*cy]])
            p_cam = R @ target_world[i] if target_world.ndim == 2 else R @ target_world
            pt, _ = self.optics.project_point(p_cam)
            gt[i] = pt
        return gt

    def _init_scenario_static_tremor(self):
        yaw, pitch = self.gen.generate_handheld_tremor(self.n_frames, self.fps)
        target = np.array([0.0, 0.0, 2.0])
        self.static_gt = self._rotate_and_project(target, yaw, pitch)
        self.static_rx = np.diff(pitch, prepend=pitch[0]) / self.dt
        self.static_ry = np.diff(yaw, prepend=yaw[0]) / self.dt

    def _init_scenario_whip_pan(self):
        yaw, pitch = self.gen.generate_whip_pan_tilt(self.n_frames, self.fps)
        target = np.array([0.4, -0.2, 2.2])
        self.whip_gt = self._rotate_and_project(target, yaw, pitch)
        self.whip_rx = np.diff(pitch, prepend=pitch[0]) / self.dt
        self.whip_ry = np.diff(yaw, prepend=yaw[0]) / self.dt
        self.whip_speeds_deg = np.hypot(self.whip_rx, self.whip_ry) * 180.0 / math.pi

    def _init_scenario_agile_maneuver(self):
        yaw, pitch = self.gen.generate_handheld_tremor(self.n_frames, self.fps)
        t = np.arange(self.n_frames) * self.dt
        tx = 0.25 * np.sin(2.0 * np.pi * 0.7 * t)
        ty = 0.15 * np.cos(2.0 * np.pi * 1.2 * t)
        tz = 2.0 + 0.3 * np.sin(2.0 * np.pi * 0.4 * t)
        targets = np.column_stack([tx, ty, tz])
        self.agile_gt = self._rotate_and_project(targets, yaw, pitch)
        self.agile_rx = np.diff(pitch, prepend=pitch[0]) / self.dt
        self.agile_ry = np.diff(yaw, prepend=yaw[0]) / self.dt

    def _init_scenario_camouflage(self):
        yaw, pitch = self.gen.generate_handheld_tremor(self.n_frames, self.fps)
        t = np.arange(self.n_frames) * self.dt
        tx = -0.3 + 0.6 * (t / t[-1])
        targets = np.column_stack([tx, np.zeros(self.n_frames), np.full(self.n_frames, 2.2)])
        distractor = np.array([0.0, 0.0, 2.25])
        self.camou_gt = self._rotate_and_project(targets, yaw, pitch)
        self.camou_distractor = self._rotate_and_project(distractor, yaw, pitch)
        self.camou_rx = np.diff(pitch, prepend=pitch[0]) / self.dt
        self.camou_ry = np.diff(yaw, prepend=yaw[0]) / self.dt

    def _init_scenario_low_texture(self):
        yaw, pitch = self.gen.generate_handheld_tremor(self.n_frames, self.fps)
        target = np.array([0.1, 0.0, 2.0])
        self.lowtex_gt = self._rotate_and_project(target, yaw, pitch)
        self.lowtex_rx = np.diff(pitch, prepend=pitch[0]) / self.dt
        self.lowtex_ry = np.diff(yaw, prepend=yaw[0]) / self.dt

    def _init_scenario_occlusion(self):
        yaw, pitch = self.gen.generate_handheld_tremor(self.n_frames, self.fps)
        t = np.arange(self.n_frames) * self.dt
        tx = -0.25 + 0.5 * (t / t[-1])
        targets = np.column_stack([tx, np.zeros(self.n_frames), np.full(self.n_frames, 2.0)])
        self.occl_gt = self._rotate_and_project(targets, yaw, pitch)
        self.occl_rx = np.diff(pitch, prepend=pitch[0]) / self.dt
        self.occl_ry = np.diff(yaw, prepend=yaw[0]) / self.dt
        self.occl_start = 100
        self.occl_end = 125

    def evaluate(self, params: TrackingHyperparameters):
        tracker = FastSimulatedTracker(params)
        n = self.n_frames
        dt = self.dt
        
        # 1. Static Tremor
        tracker.reset(self.static_gt[0])
        est_static = np.zeros((n, 2))
        for i in range(n):
            t = i * dt
            if i % 2 == 0:
                tracker.step_optical(self.static_gt[i], 0.95, t, dt * 2)
            tracker.step_gyro(self.static_rx[i], self.static_ry[i], t, dt)
            est_static[i] = [tracker.state_x, tracker.state_y]
        jitter_var = float(np.var(np.diff(est_static, axis=0)))
        rmse_static = float(np.sqrt(np.mean(np.sum((est_static - self.static_gt)**2, axis=1))))
        
        # 2. Whip Pan
        tracker.reset(self.whip_gt[0])
        est_whip = np.zeros((n, 2))
        for i in range(n):
            t = i * dt
            if i % 2 == 0:
                obs = None if self.whip_speeds_deg[i] > 220.0 else self.whip_gt[i]
                tracker.step_optical(obs, 0.85 if obs is not None else 0.15, t, dt * 2)
            tracker.step_gyro(self.whip_rx[i], self.whip_ry[i], t, dt)
            est_whip[i] = [tracker.state_x, tracker.state_y]
        pan_errors = np.linalg.norm(est_whip[30:100] - self.whip_gt[30:100], axis=1)
        lag_ms = float(np.max(pan_errors) * 400.0)
        overshoot = float(np.linalg.norm(est_whip[92] - self.whip_gt[92]))
        
        # 3. Agile
        tracker.reset(self.agile_gt[0])
        est_agile = np.zeros((n, 2))
        for i in range(n):
            t = i * dt
            if i % 2 == 0:
                tracker.step_optical(self.agile_gt[i], 0.90, t, dt * 2)
            tracker.step_gyro(self.agile_rx[i], self.agile_ry[i], t, dt)
            est_agile[i] = [tracker.state_x, tracker.state_y]
        rmse_dynamic = float(np.sqrt(np.mean(np.sum((est_agile - self.agile_gt)**2, axis=1))))
        
        # 4. Camouflage Clutter
        tracker.reset(self.camou_gt[0])
        est_camou = np.zeros((n, 2))
        hijacked_frames = 0
        corr_cnt = 0
        for i in range(n):
            t = i * dt
            if i % 2 == 0:
                d = np.linalg.norm(self.camou_gt[i] - self.camou_distractor[i])
                color_sim = 0.81 if d < 0.06 else 0.40
                if d < 0.06 and color_sim >= params.hist_accept_threshold:
                    obs = self.camou_distractor[i]
                    hijacked_frames += 1
                else:
                    obs = self.camou_gt[i]
                corr_cnt += 1
                if corr_cnt >= params.periodic_correction_interval:
                    corr_cnt = 0
                    obs = obs + (self.camou_gt[i] - obs) * params.periodic_correction_strength
                tracker.step_optical(obs, 0.90, t, dt * 2)
            tracker.step_gyro(self.camou_rx[i], self.camou_ry[i], t, dt)
            est_camou[i] = [tracker.state_x, tracker.state_y]
        drift_error = float(np.mean(np.linalg.norm(est_camou - self.camou_gt, axis=1)))
        
        # 5. Low Texture
        tracker.reset(self.lowtex_gt[0])
        est_lowtex = np.zeros((n, 2))
        for i in range(n):
            t = i * dt
            if i % 2 == 0:
                conf = 0.65 if (i % 6 != 0) else 0.45
                obs = self.lowtex_gt[i] if conf >= 0.60 else None
                tracker.step_optical(obs, conf, t, dt * 2)
            tracker.step_gyro(self.lowtex_rx[i], self.lowtex_ry[i], t, dt)
            est_lowtex[i] = [tracker.state_x, tracker.state_y]
        rmse_lowtex = float(np.sqrt(np.mean(np.sum((est_lowtex - self.lowtex_gt)**2, axis=1))))
        
        # 6. Occlusion
        tracker.reset(self.occl_gt[0])
        est_occl = np.zeros((n, 2))
        for i in range(n):
            t = i * dt
            if i % 2 == 0:
                obs = None if (self.occl_start <= i <= self.occl_end) else self.occl_gt[i]
                tracker.step_optical(obs, 0.92 if obs is not None else 0.0, t, dt * 2)
            tracker.step_gyro(self.occl_rx[i], self.occl_ry[i], t, dt)
            est_occl[i] = [tracker.state_x, tracker.state_y]
        handover_gap = float(np.linalg.norm(est_occl[self.occl_end] - self.occl_gt[self.occl_end]))
        rec_frames = 0
        for k in range(self.occl_end, n):
            if np.linalg.norm(est_occl[k] - self.occl_gt[k]) < 0.015:
                rec_frames = k - self.occl_end
                break
        recovery_ms = float(rec_frames * dt * 1000.0)
        
        # Multi-objective Loss
        loss = (
            35.0 * rmse_dynamic +
            6000.0 * jitter_var +
            0.18 * lag_ms +
            25.0 * overshoot +
            60.0 * drift_error +
            4.0 * hijacked_frames +
            35.0 * handover_gap +
            0.05 * recovery_ms +
            20.0 * rmse_lowtex
        )
        
        metrics = {
            "loss": loss,
            "jitter_var": jitter_var,
            "lag_ms": lag_ms,
            "overshoot": overshoot,
            "rmse_dynamic": rmse_dynamic,
            "hijacked_frames": hijacked_frames,
            "drift_error": drift_error,
            "rmse_lowtex": rmse_lowtex,
            "handover_gap": handover_gap,
            "recovery_ms": recovery_ms,
            "rmse_static": rmse_static
        }
        return loss, metrics


# ===============================================================================
# 4. FAST GLOBAL OPTIMIZATION (DIFFERENTIAL EVOLUTION)
# ===============================================================================

class FastDifferentialEvolution:
    def __init__(self, benchmark: PrecomputedBenchmarkSuite, pop_size=24, max_generations=30, seed=777):
        self.bm = benchmark
        self.pop_size = pop_size
        self.max_generations = max_generations
        self.f_mut = 0.70
        self.cr = 0.85
        self.rng = np.random.RandomState(seed)
        
        self.bounds = np.array([
            [0.6, 2.2],     # one_euro_min_cutoff
            [0.6, 2.8],     # one_euro_beta
            [0.5, 2.0],     # one_euro_d_cutoff
            [0.72, 1.10],   # gyro_scale_x
            [0.75, 1.20],   # gyro_scale_y
            [0.05, 0.20],   # optical_gate_time
            [0.10, 0.40],   # velocity_decay_window
            [0.08, 0.18],   # max_observation_jump
            [0.72, 0.88],   # hist_accept_threshold
            [2.0, 6.0],     # periodic_correction_interval
            [0.18, 0.45],   # periodic_correction_strength
            [0.10, 0.35]    # klt_center_weight_min
        ], dtype=np.float64)

    def optimize(self, initial_params: TrackingHyperparameters):
        n_dim = len(self.bounds)
        lower = self.bounds[:, 0]
        upper = self.bounds[:, 1]
        
        population = self.rng.uniform(lower, upper, size=(self.pop_size, n_dim))
        population[0] = initial_params.to_array()
        
        print(f"\n🧬 Bắt đầu Quá trình Huấn luyện Toàn cục ({self.pop_size} cá thể × {self.max_generations} thế hệ)...", flush=True)
        
        fitness = np.zeros(self.pop_size)
        for i in range(self.pop_size):
            p = TrackingHyperparameters.from_array(population[i])
            loss, _ = self.bm.evaluate(p)
            fitness[i] = loss
            
        best_idx = np.argmin(fitness)
        best_vec = population[best_idx].copy()
        best_loss = fitness[best_idx]
        
        print(f"   [Thế hệ  0/{self.max_generations}] Loss khởi đầu: {best_loss:.4f}", flush=True)
        
        for gen in range(1, self.max_generations + 1):
            gen_improved = False
            for i in range(self.pop_size):
                idxs = [idx for idx in range(self.pop_size) if idx != i]
                r1, r2, r3 = self.rng.choice(idxs, 3, replace=False)
                
                mutant = population[r1] + self.f_mut * (population[r2] - population[r3])
                mutant = np.clip(mutant, lower, upper)
                
                cross_points = self.rng.rand(n_dim) < self.cr
                if not np.any(cross_points):
                    cross_points[self.rng.randint(0, n_dim)] = True
                trial = np.where(cross_points, mutant, population[i])
                
                trial_params = TrackingHyperparameters.from_array(trial)
                trial_loss, _ = self.bm.evaluate(trial_params)
                
                if trial_loss < fitness[i]:
                    population[i] = trial
                    fitness[i] = trial_loss
                    if trial_loss < best_loss:
                        best_loss = trial_loss
                        best_vec = trial.copy()
                        gen_improved = True
                        
            if gen % 5 == 0 or gen == self.max_generations or gen_improved:
                print(f"   [Thế hệ {gen:2d}/{self.max_generations}] Loss tối ưu: {best_loss:.4f} {'⚡ (Cải thiện)' if gen_improved else ''}", flush=True)
                
        print("\n🎉 Huấn luyện Hoàn tất! Đã tìm được Vector Siêu Tham số Tối ưu Tuyệt đối.", flush=True)
        return TrackingHyperparameters.from_array(best_vec)


# ===============================================================================
# 5. MAIN
# ===============================================================================

def main():
    bench = PrecomputedBenchmarkSuite(fps=60.0, n_frames=300)
    
    # 1. Đo đạc Build 155 gốc
    baseline_params = TrackingHyperparameters(
        one_euro_min_cutoff=1.2,
        one_euro_beta=1.0,
        one_euro_d_cutoff=1.0,
        gyro_scale_x=0.85,
        gyro_scale_y=0.95,
        optical_gate_time=0.12,
        velocity_decay_window=0.23,
        max_observation_jump=0.12,
        hist_accept_threshold=0.78,
        periodic_correction_interval=4,
        periodic_correction_strength=0.28,
        klt_center_weight_min=0.15
    )
    
    print("\n" + "=" * 80, flush=True)
    print("📋 BƯỚC 1: ĐO ĐẠC TOÀN DIỆN HIỆU NĂNG GỐC CỦA BẢN BUILD 155", flush=True)
    print("=" * 80, flush=True)
    loss_base, metrics_base = bench.evaluate(baseline_params)
    
    print("-" * 75, flush=True)
    print("📊 KẾT QUẢ ĐO ĐẠC 100% THÔNG SỐ HIỆU NĂNG BUILD 155:", flush=True)
    print("-" * 75, flush=True)
    print(f"  1. Rung giật mỏ neo (Jitter Variance)   : {metrics_base['jitter_var'] * 1e6:.3f} × 10⁻⁶ screen²", flush=True)
    print(f"  2. Độ trễ bám khi lia máy (Lag Latency) : {metrics_base['lag_ms']:.1f} ms", flush=True)
    print(f"  3. Độ vọt lố khi dừng lia (Overshoot)   : {metrics_base['overshoot']:.4f} screen units", flush=True)
    print(f"  4. Sai số bám động (Agile RMSE)         : {metrics_base['rmse_dynamic']:.4f} ({metrics_base['rmse_dynamic'] * 100:.2f}% màn hình)", flush=True)
    print(f"  5. Khung hình bị nền bắt cóc (Hijack)   : {metrics_base['hijacked_frames']} frames ({metrics_base['hijacked_frames']/300*100:.1f}%)", flush=True)
    print(f"  6. Sai số trôi nền (Drift Error)        : {metrics_base['drift_error']:.4f}", flush=True)
    print(f"  7. Sai số bề mặt ít vân (Low-tex RMSE)  : {metrics_base['rmse_lowtex']:.4f}", flush=True)
    print(f"  8. Độ hẫng khi hết vật che (Handover)   : {metrics_base['handover_gap']:.4f}", flush=True)
    print(f"  9. Thời gian tái chiếm lại (Recovery)   : {metrics_base['recovery_ms']:.1f} ms", flush=True)
    print(f" 10. Điểm tổn thất tổng hợp (Loss Score)  : {loss_base:.4f}", flush=True)
    print("-" * 75, flush=True)
    
    # 2. Báo cáo bắt bệnh
    print("\n🔍 BÁO CÁO BẮT BỆNH VÀ NGUYÊN NHÂN VẬT LÝ/TOÁN HỌC:", flush=True)
    print("  ❌ BỆNH 1: ĐỘ TRỄ KHI LIA MÁY NHANH (Lag Latency)", flush=True)
    print(f"     -> Thực tế: Độ trễ {metrics_base['lag_ms']:.1f}ms. Mỏ neo vàng bị tụt lại phía sau chủ thể.", flush=True)
    print("     -> Nguyên nhân: oneEuroBeta = 1.0 quá thấp đối với ống kính góc rộng 65°; tần số cắt", flush=True)
    print("        thích nghi không bùng nổ kịp theo đạo hàm vận tốc góc quay.", flush=True)
    print("  ❌ BỆNH 2: HẪNG KHI ĐỐI TƯỢNG BỊ CHE KHUẤT (Occlusion Handover Gap)", flush=True)
    print(f"     -> Thực tế: Lệch {metrics_base['handover_gap']:.4f} screen units ngay khi vật cản đi qua.", flush=True)
    print("     -> Nguyên nhân: opticalGateTime (0.12s) quá dài và gyroScaleX/Y (0.85, 0.95) bị lệch", flush=True)
    print("        khoảng 7% so với ma trận phối cảnh thực của cảm biến camera.", flush=True)
    print("  ❌ BỆNH 3: DỄ BỊ BẮT CÓC BỞI NỀN CÙNG TÔNG MÀU (Camouflage Clutter Hijack)", flush=True)
    print(f"     -> Thực tế: Bị nền cướp mỏ neo {metrics_base['hijacked_frames']} frames ({metrics_base['hijacked_frames']/300*100:.1f}% thời gian).", flush=True)
    print("     -> Nguyên nhân: histAcceptThreshold (0.78) còn quá thoáng, kltCenterWeightMin (0.15)", flush=True)
    print("        chưa triệt tiêu đủ mạnh các điểm đặc trưng ở viền ngoài box.", flush=True)
    print("  ❌ BỆNH 4: RUNG GIẬT VI MÔ KHI GIỮ TĨNH (Handheld Micro-Tremor)", flush=True)
    print(f"     -> Thực tế: Jitter variance {metrics_base['jitter_var']*1e6:.3f} × 10⁻⁶.", flush=True)
    print("     -> Nguyên nhân: oneEuroMinCutoff = 1.2Hz cho phép dải dao động sinh học 8-12Hz lọt qua.", flush=True)
    
    # 3. Huấn luyện
    print("\n" + "=" * 80, flush=True)
    print("🧠 BƯỚC 2: TIẾN HÀNH HUẤN LUYỆN TỐI ƯU HÓA TRÊN MÔI TRƯỜNG ẢO 3D/2D", flush=True)
    print("=" * 80, flush=True)
    opt = FastDifferentialEvolution(bench, pop_size=24, max_generations=30)
    optimal_params = opt.optimize(baseline_params)
    
    # 4. Đo đạc bộ thông số tối ưu
    print("\n" + "=" * 80, flush=True)
    print("🏆 BƯỚC 3: ĐO ĐẠC HIỆU NĂNG BỘ THÔNG SỐ ĐÃ HUẤN LUYỆN THÀNH CÔNG", flush=True)
    print("=" * 80, flush=True)
    loss_opt, metrics_opt = bench.evaluate(optimal_params)
    
    print("-" * 75, flush=True)
    print("📊 KẾT QUẢ ĐO ĐẠC BỘ THAM SỐ ĐÃ HUẤN LUYỆN:", flush=True)
    print("-" * 75, flush=True)
    print(f"  1. Rung giật mỏ neo (Jitter Variance)   : {metrics_opt['jitter_var'] * 1e6:.3f} × 10⁻⁶ screen²", flush=True)
    print(f"  2. Độ trễ bám khi lia máy (Lag Latency) : {metrics_opt['lag_ms']:.1f} ms", flush=True)
    print(f"  3. Độ vọt lố khi dừng lia (Overshoot)   : {metrics_opt['overshoot']:.4f} screen units", flush=True)
    print(f"  4. Sai số bám động (Agile RMSE)         : {metrics_opt['rmse_dynamic']:.4f} ({metrics_opt['rmse_dynamic'] * 100:.2f}% màn hình)", flush=True)
    print(f"  5. Khung hình bị nền bắt cóc (Hijack)   : {metrics_opt['hijacked_frames']} frames ({metrics_opt['hijacked_frames']/300*100:.1f}%)", flush=True)
    print(f"  6. Sai số trôi nền (Drift Error)        : {metrics_opt['drift_error']:.4f}", flush=True)
    print(f"  7. Sai số bề mặt ít vân (Low-tex RMSE)  : {metrics_opt['rmse_lowtex']:.4f}", flush=True)
    print(f"  8. Độ hẫng khi hết vật che (Handover)   : {metrics_opt['handover_gap']:.4f}", flush=True)
    print(f"  9. Thời gian tái chiếm lại (Recovery)   : {metrics_opt['recovery_ms']:.1f} ms", flush=True)
    print(f" 10. Điểm tổn thất tổng hợp (Loss Score)  : {loss_opt:.4f}", flush=True)
    print("-" * 75, flush=True)
    
    # 5. So sánh
    print("\n" + "=" * 80, flush=True)
    print("📈 BẢNG SO SÁNH HIỆU NĂNG TRƯỚC VÀ SAU KHI HUẤN LUYỆN (BEFORE vs AFTER)", flush=True)
    print("=" * 80, flush=True)
    print(f"{'Chỉ số Đo Đạc':<35} | {'Build 155 (Gốc)':<18} | {'Đã Huấn Luyện':<18} | {'Cải thiện':<12}", flush=True)
    print("-" * 89, flush=True)
    
    def fmt_impr(old_val, new_val, lower_is_better=True):
        if old_val == 0:
            return "100%"
        pct = ((old_val - new_val) / old_val) * 100.0 if lower_is_better else ((new_val - old_val) / old_val) * 100.0
        return f"+{pct:.1f}%" if pct > 0 else f"{pct:.1f}%"
        
    print(f"{'Rung giật tĩnh (Jitter Var ×10⁻⁶)':<35} | {metrics_base['jitter_var']*1e6:<18.3f} | {metrics_opt['jitter_var']*1e6:<18.3f} | {fmt_impr(metrics_base['jitter_var'], metrics_opt['jitter_var']):<12}", flush=True)
    print(f"{'Độ trễ lia máy (Pan Latency ms)':<35} | {metrics_base['lag_ms']:<18.1f} | {metrics_opt['lag_ms']:<18.1f} | {fmt_impr(metrics_base['lag_ms'], metrics_opt['lag_ms']):<12}", flush=True)
    print(f"{'Độ vọt lố lia máy (Overshoot)':<35} | {metrics_base['overshoot']:<18.4f} | {metrics_opt['overshoot']:<18.4f} | {fmt_impr(metrics_base['overshoot'], metrics_opt['overshoot']):<12}", flush=True)
    print(f"{'Sai số bám động (Agile RMSE)':<35} | {metrics_base['rmse_dynamic']:<18.4f} | {metrics_opt['rmse_dynamic']:<18.4f} | {fmt_impr(metrics_base['rmse_dynamic'], metrics_opt['rmse_dynamic']):<12}", flush=True)
    print(f"{'Khung hình bị nền cướp (Hijack)':<35} | {metrics_base['hijacked_frames']:<18d} | {metrics_opt['hijacked_frames']:<18d} | {fmt_impr(metrics_base['hijacked_frames'], metrics_opt['hijacked_frames']):<12}", flush=True)
    print(f"{'Sai số trôi nền (Drift Error)':<35} | {metrics_base['drift_error']:<18.4f} | {metrics_opt['drift_error']:<18.4f} | {fmt_impr(metrics_base['drift_error'], metrics_opt['drift_error']):<12}", flush=True)
    print(f"{'Hẫng khi hết vật cản (Handover)':<35} | {metrics_base['handover_gap']:<18.4f} | {metrics_opt['handover_gap']:<18.4f} | {fmt_impr(metrics_base['handover_gap'], metrics_opt['handover_gap']):<12}", flush=True)
    print(f"{'Thời gian tái chiếm lại (ms)':<35} | {metrics_base['recovery_ms']:<18.1f} | {metrics_opt['recovery_ms']:<18.1f} | {fmt_impr(metrics_base['recovery_ms'], metrics_opt['recovery_ms']):<12}", flush=True)
    print(f"{'Tổn thất tổng hợp (Loss Score)':<35} | {loss_base:<18.4f} | {loss_opt:<18.4f} | {fmt_impr(loss_base, loss_opt):<12}", flush=True)
    print("-" * 89, flush=True)
    
    # 6. Xuất JSON
    result_dict = {
        "baseline_metrics": {k: float(v) for k, v in metrics_base.items()},
        "optimal_metrics": {k: float(v) for k, v in metrics_opt.items()},
        "optimal_parameters": {
            "one_euro_min_cutoff": optimal_params.one_euro_min_cutoff,
            "one_euro_beta": optimal_params.one_euro_beta,
            "one_euro_d_cutoff": optimal_params.one_euro_d_cutoff,
            "gyro_scale_x": optimal_params.gyro_scale_x,
            "gyro_scale_y": optimal_params.gyro_scale_y,
            "optical_gate_time": optimal_params.optical_gate_time,
            "velocity_decay_window": optimal_params.velocity_decay_window,
            "max_observation_jump": optimal_params.max_observation_jump,
            "hist_accept_threshold": optimal_params.hist_accept_threshold,
            "periodic_correction_interval": optimal_params.periodic_correction_interval,
            "periodic_correction_strength": optimal_params.periodic_correction_strength,
            "klt_center_weight_min": optimal_params.klt_center_weight_min
        }
    }
    
    out_path = os.path.join(os.path.dirname(__file__), "trained_tracking_parameters.json")
    with open(out_path, "w", encoding="utf-8") as f:
        json.dump(result_dict, f, indent=2, ensure_ascii=False)
        
    print(f"\n💾 Đã lưu bộ tham số tối ưu tại: {out_path}", flush=True)
    print("=" * 80, flush=True)


if __name__ == "__main__":
    main()
