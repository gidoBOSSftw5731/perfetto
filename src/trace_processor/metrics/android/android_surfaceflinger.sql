--
-- Copyright 2020 The Android Open Source Project
--
-- Licensed under the Apache License, Version 2.0 (the "License");
-- you may not use this file except in compliance with the License.
-- You may obtain a copy of the License at
--
--     https://www.apache.org/licenses/LICENSE-2.0
--
-- Unless required by applicable law or agreed to in writing, software
-- distributed under the License is distributed on an "AS IS" BASIS,
-- WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
-- See the License for the specific language governing permissions and
-- limitations under the License.

SELECT RUN_METRIC(
  'android/frame_missed.sql',
  'track_name', 'PrevFrameMissed',
  'output', 'frame_missed'
);
SELECT RUN_METRIC(
  'android/frame_missed.sql',
  'track_name', 'PrevHwcFrameMissed',
  'output', 'hwc_frame_missed'
);
SELECT RUN_METRIC(
  'android/frame_missed.sql',
  'track_name', 'PrevGpuFrameMissed',
  'output', 'gpu_frame_missed'
);

DROP VIEW IF EXISTS android_surfaceflinger_event;
CREATE VIEW android_surfaceflinger_event AS
SELECT
  'slice' AS track_type,
  'Android Missed Frames' AS track_name,
  ts,
  dur,
  'Frame missed' AS slice_name
FROM frame_missed
WHERE value = 1 AND ts IS NOT NULL;

DROP VIEW IF EXISTS surfaceflinger_track;
CREATE VIEW surfaceflinger_track AS
SELECT tr.id AS track_id, t.utid, t.tid
FROM process p JOIN thread t ON p.upid = t.upid
     JOIN thread_track tr ON tr.utid = t.utid
WHERE p.cmdline='/system/bin/surfaceflinger';

DROP VIEW IF EXISTS gpu_waiting_start;
CREATE VIEW gpu_waiting_start AS
SELECT
  CAST(SUBSTRING(s.name, 28, LENGTH(s.name)) AS UINT32) AS fence_id,
  ts AS start_ts
FROM slices s JOIN surfaceflinger_track t ON s.track_id = t.track_id
WHERE s.name LIKE 'Trace GPU completion fence %';

DROP VIEW IF EXISTS gpu_waiting_end;
CREATE VIEW gpu_waiting_end AS
SELECT
  CAST(SUBSTRING(s.name, 28, LENGTH(s.name)) AS UINT32) AS fence_id,
  dur,
  ts+dur AS end_ts
FROM slices s JOIN surfaceflinger_track t ON s.track_id = t.track_id
WHERE s.name LIKE 'waiting for GPU completion %';

DROP VIEW IF EXISTS gpu_waiting_span;
CREATE VIEW gpu_waiting_span AS
SELECT
  fence_id,
  ts,
  dur
FROM (
  SELECT
    fence_id,
    ts,
    LEAD(ts) OVER (ORDER BY fence_id, event_type) - ts AS dur,
    LEAD(fence_id) OVER (ORDER BY fence_id, event_type) AS next_fence_id,
    event_type
  FROM (
    SELECT fence_id, start_ts AS ts, 0 AS event_type FROM gpu_waiting_start
    UNION
    SELECT fence_id, end_ts AS ts, 1 AS event_type FROM gpu_waiting_end
  )
  ORDER BY fence_id, event_type
)
WHERE event_type = 0 AND fence_id = next_fence_id;

DROP VIEW IF EXISTS android_surfaceflinger_output;
CREATE VIEW android_surfaceflinger_output AS
SELECT
  AndroidSurfaceflingerMetric(
    'missed_frames', (SELECT COUNT(1) FROM frame_missed WHERE value=1),
    'missed_hwc_frames', (SELECT COUNT(1) FROM hwc_frame_missed WHERE value=1),
    'missed_gpu_frames', (SELECT COUNT(1) FROM gpu_frame_missed WHERE value=1),
    'missed_frame_rate', (SELECT AVG(value) FROM frame_missed),
    'missed_hwc_frame_rate', (SELECT AVG(value) FROM hwc_frame_missed),
    'missed_gpu_frame_rate', (SELECT AVG(value) FROM gpu_frame_missed),
    'gpu_invocations', (SELECT COUNT(1) FROM gpu_waiting_end),
    'avg_gpu_waiting_dur_ms', (SELECT AVG(dur)/1e6 FROM gpu_waiting_span),
    'total_non_empty_gpu_waiting_dur_ms',
        (SELECT SUM(dur)/1e6 FROM gpu_waiting_end)
  );
