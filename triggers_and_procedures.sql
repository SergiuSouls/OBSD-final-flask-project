-- ============================================
-- ТАБЛИЦІ ДЛЯ ЛОГУВАННЯ ТА ІСТОРІЇ
-- ============================================

-- Таблиця для логування змін цін
CREATE TABLE IF NOT EXISTS price_history (
    id SERIAL PRIMARY KEY,
    product_id INTEGER NOT NULL,
    old_price DECIMAL(10, 2),
    new_price DECIMAL(10, 2),
    changed_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (product_id) REFERENCES products(id) ON DELETE CASCADE
);

-- Таблиця для логування продажів
CREATE TABLE IF NOT EXISTS sales_log (
    id SERIAL PRIMARY KEY,
    product_id INTEGER NOT NULL,
    product_name VARCHAR(255),
    quantity_sold INTEGER DEFAULT 1,
    price_at_sale DECIMAL(10, 2),
    sale_date TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (product_id) REFERENCES products(id) ON DELETE SET NULL
);

-- Таблиця для сповіщень про низькі залишки
CREATE TABLE IF NOT EXISTS low_stock_alerts (
    id SERIAL PRIMARY KEY,
    product_id INTEGER NOT NULL,
    product_name VARCHAR(255),
    current_quantity INTEGER,
    alert_date TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    is_resolved BOOLEAN DEFAULT FALSE,
    FOREIGN KEY (product_id) REFERENCES products(id) ON DELETE CASCADE
);

-- ============================================
-- ТРИГЕР 1: Логування змін цін
-- ============================================

-- Функція для логування змін цін
CREATE OR REPLACE FUNCTION log_price_change()
RETURNS TRIGGER AS $$
BEGIN
    -- Якщо ціна змінилась
    IF OLD.price != NEW.price THEN
        INSERT INTO price_history (product_id, old_price, new_price)
        VALUES (NEW.id, OLD.price, NEW.price);
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Тригер на зміну ціни
DROP TRIGGER IF EXISTS trigger_price_change ON products;
CREATE TRIGGER trigger_price_change
    AFTER UPDATE ON products
    FOR EACH ROW
    EXECUTE FUNCTION log_price_change();

-- ============================================
-- ТРИГЕР 2: Автоматичне логування продажів
-- ============================================

-- Функція для логування продажів
CREATE OR REPLACE FUNCTION log_sale()
RETURNS TRIGGER AS $$
BEGIN
    -- Якщо кількість товару зменшилась
    IF OLD.quantity > NEW.quantity THEN
        INSERT INTO sales_log (product_id, product_name, quantity_sold, price_at_sale)
        VALUES (NEW.id, NEW.name, OLD.quantity - NEW.quantity, NEW.price);
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Тригер на зменшення кількості товару
DROP TRIGGER IF EXISTS trigger_log_sale ON products;
CREATE TRIGGER trigger_log_sale
    AFTER UPDATE ON products
    FOR EACH ROW
    EXECUTE FUNCTION log_sale();

-- ============================================
-- ТРИГЕР 3: Сповіщення про низькі залишки
-- ============================================

-- Функція для перевірки низьких залишків
CREATE OR REPLACE FUNCTION check_low_stock()
RETURNS TRIGGER AS $$
BEGIN
    -- Якщо залишок товару <= 2
    IF NEW.quantity <= 2 AND NEW.quantity >= 0 THEN
        -- Перевіряємо, чи немає вже активного сповіщення
        IF NOT EXISTS (
            SELECT 1 FROM low_stock_alerts
            WHERE product_id = NEW.id AND is_resolved = FALSE
        ) THEN
            INSERT INTO low_stock_alerts (product_id, product_name, current_quantity)
            VALUES (NEW.id, NEW.name, NEW.quantity);
        END IF;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Тригер на низькі залишки
DROP TRIGGER IF EXISTS trigger_low_stock ON products;
CREATE TRIGGER trigger_low_stock
    AFTER UPDATE ON products
    FOR EACH ROW
    EXECUTE FUNCTION check_low_stock();

-- ============================================
-- ТРИГЕР 4: Запобігання негативних залишків
-- ============================================

-- Функція для перевірки кількості
CREATE OR REPLACE FUNCTION prevent_negative_quantity()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.quantity < 0 THEN
        RAISE EXCEPTION 'Кількість товару не може бути від''ємною!';
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Тригер на перевірку кількості
DROP TRIGGER IF EXISTS trigger_prevent_negative ON products;
CREATE TRIGGER trigger_prevent_negative
    BEFORE INSERT OR UPDATE ON products
    FOR EACH ROW
    EXECUTE FUNCTION prevent_negative_quantity();

-- ============================================
-- ПРОЦЕДУРА 1: Поповнення товару
-- ============================================

CREATE OR REPLACE FUNCTION restock_product(
    p_product_id INTEGER,
    p_quantity INTEGER
)
RETURNS TEXT AS $$
DECLARE
    v_product_name VARCHAR(255);
    v_old_quantity INTEGER;
    v_new_quantity INTEGER;
BEGIN
    -- Перевірка існування товару
    SELECT name, quantity INTO v_product_name, v_old_quantity
    FROM products
    WHERE id = p_product_id;

    IF NOT FOUND THEN
        RETURN 'Помилка: Товар не знайдено!';
    END IF;

    -- Перевірка коректності кількості
    IF p_quantity <= 0 THEN
        RETURN 'Помилка: Кількість має бути більше 0!';
    END IF;

    -- Оновлення кількості
    UPDATE products
    SET quantity = quantity + p_quantity
    WHERE id = p_product_id
    RETURNING quantity INTO v_new_quantity;

    -- Розв'язання сповіщень про низькі залишки
    UPDATE low_stock_alerts
    SET is_resolved = TRUE
    WHERE product_id = p_product_id AND is_resolved = FALSE;

    RETURN format('Успішно! %s: було %s, стало %s (+%s)',
                  v_product_name, v_old_quantity, v_new_quantity, p_quantity);
END;
$$ LANGUAGE plpgsql;



CREATE OR REPLACE FUNCTION apply_discount(
    p_product_id INTEGER,
    p_discount_percent DECIMAL
)
RETURNS TEXT AS $$
DECLARE
    v_product_name VARCHAR(255);
    v_old_price DECIMAL(10, 2);
    v_new_price DECIMAL(10, 2);
BEGIN
    SELECT name, price INTO v_product_name, v_old_price
    FROM products
    WHERE id = p_product_id;

    IF NOT FOUND THEN
        RETURN 'Помилка: Товар не знайдено!';
    END IF;

    -- Перевірка коректності знижки
    IF p_discount_percent <= 0 OR p_discount_percent > 100 THEN
        RETURN 'Помилка: Знижка має бути від 1% до 100%!';
    END IF;

    -- Розрахунок нової ціни
    v_new_price := v_old_price * (1 - p_discount_percent / 100);

    -- Оновлення ціни
    UPDATE products
    SET price = v_new_price
    WHERE id = p_product_id;

    RETURN format('Знижка %s%% на "%s": %s грн → %s грн (економія: %s грн)',
                  p_discount_percent, v_product_name,
                  v_old_price, v_new_price, v_old_price - v_new_price);
END;
$$ LANGUAGE plpgsql;

-- ============================================
-- ПРОЦЕДУРА 3: Статистика продажів
-- ============================================

CREATE OR REPLACE FUNCTION get_sales_stats(
    p_days INTEGER DEFAULT 30
)
RETURNS TABLE (
    product_name VARCHAR(255),
    total_sold INTEGER,
    total_revenue DECIMAL(10, 2),
    last_sale_date TIMESTAMP
) AS $$
BEGIN
    RETURN QUERY
    SELECT
        sl.product_name,
        SUM(sl.quantity_sold)::INTEGER as total_sold,
        SUM(sl.quantity_sold * sl.price_at_sale) as total_revenue,
        MAX(sl.sale_date) as last_sale_date
    FROM sales_log sl
    WHERE sl.sale_date >= CURRENT_TIMESTAMP - (p_days || ' days')::INTERVAL
    GROUP BY sl.product_name
    ORDER BY total_revenue DESC;
END;
$$ LANGUAGE plpgsql;

-- ============================================
-- ПРОЦЕДУРА 4: Топ товарів за продажами
-- ============================================

CREATE OR REPLACE FUNCTION get_top_products(
    p_limit INTEGER DEFAULT 5
)
RETURNS TABLE (
    rank INTEGER,
    product_name VARCHAR(255),
    times_sold INTEGER,
    total_revenue DECIMAL(10, 2)
) AS $$
BEGIN
    RETURN QUERY
    SELECT
        ROW_NUMBER() OVER (ORDER BY SUM(sl.quantity_sold) DESC)::INTEGER as rank,
        sl.product_name,
        SUM(sl.quantity_sold)::INTEGER as times_sold,
        SUM(sl.quantity_sold * sl.price_at_sale) as total_revenue
    FROM sales_log sl
    GROUP BY sl.product_name
    ORDER BY times_sold DESC
    LIMIT p_limit;
END;
$$ LANGUAGE plpgsql;

-- ============================================
-- ТЕСТОВІ ЗАПИТИ
-- ============================================

-- Приклад використання процедур:

-- 1. Поповнення товару
-- SELECT restock_product(1, 10);

-- 2. Застосування знижки
-- SELECT apply_discount(1, 15);

-- 3. Статистика продажів за останні 7 днів
-- SELECT * FROM get_sales_stats(7);

-- 4. Топ-3 найпопулярніших товари
-- SELECT * FROM get_top_products(3);

-- Перегляд історії цін
-- SELECT * FROM price_history ORDER BY changed_at DESC;

-- Перегляд логу продажів
-- SELECT * FROM sales_log ORDER BY sale_date DESC;

-- Перегляд сповіщень про низькі залишки
-- SELECT * FROM low_stock_alerts WHERE is_resolved = FALSE;