-- Re-create `price` (thousands of dong, float) from price_vnd. This restores the
-- VALUES, not the pre-drop column: any write made while `price` was gone exists
-- only in price_vnd, so it is converted back here (price_vnd / 1000.0).
-- After this, v4 and v3 can run; v2 only once this has finished.
ALTER TABLE menu_items ADD COLUMN price REAL CHECK (price > 0);
UPDATE menu_items SET price = price_vnd / 1000.0 WHERE price_vnd IS NOT NULL;
