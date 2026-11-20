\set ON_ERROR_STOP on
SELECT setseed(0.5);
INSERT INTO ref.productos
SELECT g, 'producto ' || g,
       (ARRAY['abarrotes', 'limpieza', 'tecnologia', 'hogar', 'ropa', 'juguetes', 'libros', 'deportes'])[1 + g % 8],
       round((5 + random() * 495)::numeric, 2)
FROM generate_series(1, 5000) g;
