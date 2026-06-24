-- 1. Nettoyage (optionnel, pour repartir à neuf si besoin)
DROP TABLE IF EXISTS fact_ecommerce_lines CASCADE;
DROP TABLE IF EXISTS fact_shipment_lines CASCADE;
DROP TABLE IF EXISTS dim_distances CASCADE;
DROP TABLE IF EXISTS dim_shipment_headers CASCADE;
DROP TABLE IF EXISTS dim_articles CASCADE;
DROP TABLE IF EXISTS dim_customers CASCADE;
DROP TABLE IF EXISTS dim_date CASCADE;

-- 2. Création des tables de Dimensions de premier niveau (les branches externes du flocon)
CREATE TABLE dim_date (
    date_id DATE PRIMARY KEY,
    year SMALLINT,
    quarter SMALLINT,
    month SMALLINT,
    month_name VARCHAR(50),
    week SMALLINT,
    day_of_month SMALLINT,
    day_of_week SMALLINT,
    day_name VARCHAR(50),
    is_weekend BOOLEAN
);

CREATE TABLE dim_customers (
    customer_id VARCHAR(100) PRIMARY KEY,
    name VARCHAR(255),
    country VARCHAR(100),
    post_code VARCHAR(50),
    location_code VARCHAR(100),
    currency_code VARCHAR(10),
    salesperson_code VARCHAR(100)
);

CREATE TABLE dim_articles (
    article_id VARCHAR(100) PRIMARY KEY,
    description VARCHAR(255),
    unit_of_measure VARCHAR(50),
    type VARCHAR(100),
    item_category VARCHAR(100),
    unit_price DECIMAL(15,4),
    unit_cost DECIMAL(15,4),
    costing_method VARCHAR(50)
);

-- 3. Création des sous-dimensions (Flocon)
CREATE TABLE dim_shipment_headers (
    header_id VARCHAR(100) PRIMARY KEY,
    customer_id VARCHAR(100) REFERENCES dim_customers(customer_id),
    order_no VARCHAR(100),
    shipment_date DATE,
    posting_date DATE,
    ship_to_city VARCHAR(100),
    ship_to_country VARCHAR(10),
    ship_to_post_code VARCHAR(50),
    location_code VARCHAR(100),
    shipment_method VARCHAR(100),
    salesperson_code VARCHAR(100)
);

CREATE TABLE dim_distances (
    id SERIAL PRIMARY KEY,
    order_id VARCHAR(100), -- Lié graphiquement à dim_shipment_headers(order_no / header_id)
    origin VARCHAR(255),
    destination VARCHAR(255),
    distance_km DECIMAL(10,2),
    duration_min DECIMAL(10,2),
    extracted_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- 4. Création des Tables de Faits centrales
CREATE TABLE fact_shipment_lines (
    id SERIAL PRIMARY KEY,
    document_no VARCHAR(100) REFERENCES dim_shipment_headers(header_id),
    line_no INTEGER,
    article_id VARCHAR(100) REFERENCES dim_articles(article_id),
    quantity DECIMAL(15,4),
    uom_code VARCHAR(50),
    gross_weight DECIMAL(15,4),
    net_weight DECIMAL(15,4),
    unit_volume DECIMAL(15,4),
    location_code VARCHAR(100),
    shipment_date DATE REFERENCES dim_date(date_id)
);

CREATE TABLE fact_ecommerce_lines (
    id SERIAL PRIMARY KEY,
    invoice_no VARCHAR(100),
    stock_code VARCHAR(100),
    description VARCHAR(255),
    quantity DECIMAL(15,4),
    unit_price DECIMAL(15,4),
    invoice_date TIMESTAMP,
    customer_id VARCHAR(100), -- Lié de manière logique/externe
    country VARCHAR(255),
    country_iso2 CHAR(2),
    total_amount DECIMAL(15,4)
);
