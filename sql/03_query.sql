-- 両者に投げる同一の集計クエリ
SELECT payment_type, count(*) AS trips, avg(total_amount) AS avg_fare
FROM trips
GROUP BY payment_type
ORDER BY trips DESC;
