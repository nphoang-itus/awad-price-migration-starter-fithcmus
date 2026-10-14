-- Contract: drop the old float column. Run ONLY when v4 (which neither reads
-- nor writes `price`) is on every instance. After this, v1-v3 cannot run.
ALTER TABLE menu_items DROP COLUMN price;
