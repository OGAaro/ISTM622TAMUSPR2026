#!/bin/bash

#-----------------------------------------------------------------------------------------------------------------------
# Amazon EC2 Automated Script                                                                                          -
#                                                                                                                      -
# This automated srcipt installs Mariadb, performs an ETL process to load and transform raw data. Includes triggers    -
# and materialized views.                                                                                              -
#                                                                                                                      -
#                                                                                                                      -
#                                                                                                                      -
#                                                                                                                      -
#                                                                                                                      -
#-----------------------------------------------------------------------------------------------------------------------

exec > >(tee /var/log/user-data.log|logger -t user-data -s 2>/dev/console) 2>&1

## Must set script to noninteractive to perform an unattended installation
export DEBIAN_FRONTEND=noninteractive
echo "=== [1/6] Script started ==="
touch /root/1-script-started

#Update and install updated packages to ensure we have the latest security patches and updates before installing mariadb
echo "=== [2/6] Updating and upgrading system packages ==="
apt update
apt upgrade -y

echo "=== [1/6] Script started ==="
touch /root/2-packages-upgraded
echo "System packages updated successfully."

# Installing and removing wordpress to create the necessary directories and files for the manual installation later.
# This is required because the official package does not include the latest version of wordpress.
echo "=== [3/6] Installing and removing WordPress to scaffold directories ==="
apt install wordpress -y
apt remove wordpress -y

touch /root/3-wordpress-shortcut-installed
echo "WordPress scaffolding complete."

# -------------------------------------------------------
# Remove the Ubuntu-repo version of MariaDB that was 
# pulled in as a WordPress dependency before installing
# from the official MariaDB repo to avoid version conflicts
# -------------------------------------------------------
apt remove --purge -y mariadb-server mariadb-client mariadb-common mysql-common 2>/dev/null || true
apt autoremove -y
apt autoclean -y

touch /root/3b-mariadb-ubuntu-version-purged

# Installing MariaDB from the official repository to get the latest version
echo "=== [4/6] Installing dependencies and adding MariaDB repository ==="
apt install apt-transport-https curl -y
mkdir -p /etc/apt/keyrings
curl -fsSL -o /etc/apt/keyrings/mariadb-keyring.pgp 'https://mariadb.org/mariadb_release_signing_key.pgp'
echo "MariaDB signing key downloaded."

cat > /etc/apt/sources.list.d/mariadb.sources <<'EOF'
# MariaDB 11.8 repository list - created 2026-02-06 00:46 UTC
# https://mariadb.org/download/
X-Repolib-Name: MariaDB
Types: deb
# URIs: https://deb.mariadb.org/11.8/ubuntu
URIs: https://mirrors.accretive-networks.net/mariadb/repo/11.8/ubuntu
Suites: noble
Components: main main/debug
Signed-By: /etc/apt/keyrings/mariadb-keyring.pgp
EOF
echo "MariaDB repository added."

echo "=== [5/6] Installing MariaDB Server ==="
apt update
apt install mariadb-server -y

#mariadb starts automatically after installation on ubuntu

touch /root/4-mariadb-installed
echo "MariaDB installed successfully."
echo "=== Installation Complete ==="

# -------------------------------------------------------
# Create Unprivileged User
# -------------------------------------------------------

echo "=== [1/6] Create Unprivileged User Started==="
USERNAME="adaniels"
PASSWORD='$tr0ngpassword'
COMMENT="Application Service User"
UIN="531002509"
SSH_DIR="/home/${USERNAME}/.ssh"


echo "=== [2/6] Create User with Home Directory ==="
# Create unprivileged user with home directory and bash shell
useradd -m -s /bin/bash -c "$COMMENT" "$USERNAME"

# Lock password login (SSH key auth only — EC2 best practice)
passwd -l "$USERNAME"

# Set up SSH key access using the same .pem key as the ubuntu user
mkdir -p "$SSH_DIR"
cp /home/ubuntu/.ssh/authorized_keys "$SSH_DIR/authorized_keys"
chown -R "${USERNAME}:${USERNAME}" "$SSH_DIR"
chmod 700 "$SSH_DIR"
chmod 600 "$SSH_DIR/authorized_keys"

# Ensure user has NO elevated group membership
gpasswd -d "$USERNAME" sudo    2>/dev/null || true
gpasswd -d "$USERNAME" adm     2>/dev/null || true
gpasswd -d "$USERNAME" dialout 2>/dev/null || true

# -------------------------------------------------------
# Grant targeted MariaDB execution permission ONLY
# This allows the user to run mariadb without a password
# prompt via sudo, without granting full root access
# -------------------------------------------------------
cat > /etc/sudoers.d/${USERNAME}-mariadb <<EOF
# Allow ${USERNAME} to execute mariadb only — no other sudo privileges
${USERNAME} ALL=(root) NOPASSWD: /usr/bin/mariadb, /usr/sbin/mariadb
EOF

# Lock down the sudoers file (required permissions for sudo to accept it)
chmod 440 /etc/sudoers.d/${USERNAME}-mariadb

# Add a shell alias so the user can just type 'mariadb' without needing 'sudo mariadb'
echo "alias mariadb='sudo mariadb'" >> /home/${USERNAME}/.bashrc
chown "${USERNAME}:${USERNAME}" /home/${USERNAME}/.bashrc

touch /root/5-nonprivuser-created

echo "User '${USERNAME}' created successfully on $(date)" >> /var/log/user-data.log
id "$USERNAME" >> /var/log/user-data.log

#Install unzip packages
apt install unzip -y

touch /root/6-unzip-installed

#download data files
sudo -u ${USERNAME} wget -O /home/${USERNAME}/${UIN}.zip https://622.gomillion.org/data/${UIN}.zip

touch /root/7-downlod-CSV-zip

#unzip data files
sudo -u ${USERNAME} unzip /home/${USERNAME}/${UIN}.zip -d /home/${USERNAME}

touch /root/8-unzipped-CSV-files

# Write SQL commands to etl.sql in nonprivuser's home directory
#must use backticks when creating order table as order is a reserved keyword
#ran into error when trying to create foreign key references without using BIGINT UNSIGNED for serial fields

#Create database and create nonpriv database user
mariadb -e "CREATE USER IF NOT EXISTS '${USERNAME}'@'localhost' IDENTIFIED BY '${PASSWORD}';"
mariadb -e "DROP DATABASE IF EXISTS POS;"
mariadb -e "CREATE DATABASE POS;"
mariadb -e "GRANT ALL PRIVILEGES ON POS.* TO '${USERNAME}'@'localhost' WITH GRANT OPTION;"
mariadb -e "GRANT FILE ON *.* TO 'adaniels'@'localhost';"
mariadb -e "FLUSH PRIVILEGES;"

cat > /home/${USERNAME}/etl.sql <<'EOF'
--=================================================
-- ETL SQL Script for POS Database
--=================================================

--=================================================
-- STEP: 1 CREATE DATABASE AND TABLES
--=================================================

--DROP DATABASE IF EXISTS POS;
--CREATE DATABASE POS;
USE POS;

/* city table created first so that customer table can refer to zip PK*/
CREATE TABLE City(
  zip         DECIMAL(5,0) ZEROFILL PRIMARY KEY,
  city        VARCHAR(32),
  state  VARCHAR(4)
);
CREATE TABLE Customer(
  id          SERIAL PRIMARY KEY,
  firstName   VARCHAR(32),
  lastName    VARCHAR(30),
  email       VARCHAR(128),
  address1    VARCHAR(100),
  address2    VARCHAR(50),
  phone       VARCHAR(32),
  birthDate   DATE,
  zip         DECIMAL(5,0) ZEROFILL, 
  constraint fk_customer_city FOREIGN KEY (zip) REFERENCES City(zip)

);

/*must use order backticks as order is a reserved keyword */
CREATE TABLE `Order` (
  id SERIAL   PRIMARY KEY,
  datePlaced  DATETIME,
  dateShipped DATETIME,
  customer_id BIGINT UNSIGNED,
  constraint fk_order_customer FOREIGN KEY (customer_id) REFERENCES Customer(id)
);

CREATE TABLE Product(
  id                SERIAL PRIMARY KEY,
  name              VARCHAR(128),
  currentPrice      DECIMAL(6,2),
  availableQuantity INT
);

CREATE TABLE Orderline(
  order_id    BIGINT UNSIGNED,
  product_id  BIGINT UNSIGNED,
  quantity    INT,
  PRIMARY KEY (order_id, product_id),
  constraint fk_orderline_order   FOREIGN KEY (order_id)   REFERENCES `Order`(id),
  constraint fk_orderline_product FOREIGN KEY (product_id) REFERENCES Product(id)
);

CREATE TABLE PriceHistory(
  id          SERIAL PRIMARY KEY,
  oldPrice    DECIMAL(6,2),
  newPrice    DECIMAL(6,2),
  ts          TIMESTAMP,
  product_id  BIGINT UNSIGNED,
  constraint fk_pricehistory_product FOREIGN KEY (product_id) REFERENCES Product(id)
);

--=================================================
-- STEP: 2 CREATE TEMP TABLES TO HOLD RAW DATA
--=================================================

DROP TABLE IF EXISTS stg_customers;
DROP TABLE IF EXISTS stg_products;
DROP TABLE IF EXISTS stg_orders;
DROP TABLE IF EXISTS stg_orderlines;


CREATE TABLE stg_customer (
  row_id INT AUTO_INCREMENT PRIMARY KEY,
  loaded_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  status VARCHAR(20) DEFAULT 'pending',

  customer_id   VARCHAR(50),
  firstName     VARCHAR(32),
  lastName      VARCHAR(30),
  city          VARCHAR(32),
  state         VARCHAR(4),
  zip           VARCHAR(10),
  address1      VARCHAR(100),
  address2      VARCHAR(50),
  email         VARCHAR(128),
  birthDate     VARCHAR(15)
  

);

LOAD DATA LOCAL INFILE '/home/adaniels/customers.csv'
INTO TABLE stg_customer
FIELDS TERMINATED BY ','
OPTIONALLY ENCLOSED BY '"'
LINES TERMINATED BY '\n'
IGNORE 1 LINES
(customer_id, firstName, lastName, city, state, zip, address1, address2, email, birthDate);

CREATE TABLE stg_product (
  row_id INT AUTO_INCREMENT PRIMARY KEY,
  loaded_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  status VARCHAR(20) DEFAULT 'pending',

  product_id        VARCHAR(50),
  name VARCHAR(128),
  currentPrice      VARCHAR(20),
  availableQuantity VARCHAR(20)

);

LOAD DATA LOCAL INFILE '/home/adaniels/products.csv'
INTO TABLE stg_product
FIELDS TERMINATED BY ','
OPTIONALLY ENCLOSED BY '"'
LINES TERMINATED BY '\n'
IGNORE 1 LINES
(product_id, name, currentPrice, availableQuantity);

CREATE TABLE stg_order (
  row_id INT AUTO_INCREMENT PRIMARY KEY,
  loaded_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  status VARCHAR(20) DEFAULT 'pending',

  order_id    VARCHAR(50),
  customer_id VARCHAR(50),
  datePlaced  VARCHAR(20),
  dateShipped VARCHAR(20)
  

);

LOAD DATA LOCAL INFILE '/home/adaniels/orders.csv'
INTO TABLE stg_order
FIELDS TERMINATED BY ','
OPTIONALLY ENCLOSED BY '"'
LINES TERMINATED BY '\n'
IGNORE 1 LINES
(order_id, customer_id, datePlaced, dateShipped);



CREATE TABLE stg_orderline(
  row_id INT AUTO_INCREMENT PRIMARY KEY,
  loaded_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  status VARCHAR(20) DEFAULT 'pending',
  
  order_id    VARCHAR(50),
  product_id  VARCHAR(50)
);

LOAD DATA LOCAL INFILE '/home/adaniels/orderlines.csv'
INTO TABLE stg_orderline
FIELDS TERMINATED BY ','
OPTIONALLY ENCLOSED BY '"'
LINES TERMINATED BY '\n'
IGNORE 1 LINES
(order_id, product_id);



CREATE TABLE stg_city(
  row_id INT AUTO_INCREMENT PRIMARY KEY,
  loaded_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  status VARCHAR(20) DEFAULT 'pending',

  zip         VARCHAR(10),
  city        VARCHAR(32),
  state       VARCHAR(4)
);

CREATE TABLE stg_pricehistory(
  row_id INT AUTO_INCREMENT PRIMARY KEY,
  loaded_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  status VARCHAR(20) DEFAULT 'pending',

  pricehistory_id VARCHAR(50),
  oldPrice        VARCHAR(20),
  newPrice        VARCHAR(20),
  ts              VARCHAR(20),
  product_id      VARCHAR(50)
);

-- ============================================================
-- TRANSFORM: VALIDATE STAGING DATA
-- ============================================================

--CUSTOMERS TABLE
UPDATE stg_customer SET status = 'rejected'
WHERE customer_id IS NULL OR customer_id = ''
   OR firstName IS NULL OR firstName = ''
   OR lastName IS NULL OR lastName = ''
   OR email IS NULL OR email = '';

UPDATE stg_customer SET
    firstName  = TRIM(firstName),
    lastName   = TRIM(lastName),
    email      = TRIM(email),
    address1   = TRIM(address1),
    address2   = TRIM(address2),
    city       = TRIM(city),
    state      = TRIM(state),
    zip        = TRIM(zip)
WHERE status = 'pending';

-- PRODUCTS

-- 1. Strip '$' character from price field
UPDATE stg_product SET currentPrice = REPLACE(currentPrice, '$', '')
WHERE status = 'pending';  
-- 2. Strip ',' character from price field
UPDATE stg_product SET currentPrice = REPLACE(currentPrice, ',', '')
WHERE status = 'pending';  

--3. Flag for invalid/missing data
UPDATE stg_product SET status = 'rejected'
WHERE product_id IS NULL OR product_id = ''
   OR name IS NULL OR name = ''
   OR currentPrice IS NULL OR currentPrice = ''
   OR (CAST(currentPrice AS DECIMAL(6,2)) <= 0);

UPDATE stg_product SET name = TRIM(name)
WHERE status = 'pending';

UPDATE stg_order SET status = 'rejected'
WHERE order_id IS NULL OR order_id = ''
   OR customer_id IS NULL OR customer_id = '';
UPDATE stg_orderline SET status = 'rejected'
WHERE order_id IS NULL OR order_id = ''
   OR product_id IS NULL OR product_id = '';

-- Convert 'Cancelled' dateShipped values to NULL
UPDATE stg_order SET dateShipped = NULL
WHERE status = 'pending'
  AND LOWER(dateShipped) = 'cancelled';

-- ============================================================
-- LOAD: ADD source_id COLUMNS TO PRODUCTION TABLES
-- ============================================================
ALTER TABLE Customer ADD COLUMN source_id VARCHAR(50);
ALTER TABLE Product ADD COLUMN source_id VARCHAR(50);
ALTER TABLE `Order` ADD COLUMN source_id VARCHAR(50);

-- ============================================================
-- LOAD: CITY
-- ============================================================
INSERT IGNORE INTO City (zip, city, state)
SELECT DISTINCT
    CAST(zip AS DECIMAL(5,0)),
    TRIM(city),
    TRIM(state)
FROM stg_customer
WHERE status = 'pending'
  AND zip IS NOT NULL AND zip != '';

-- ============================================================
-- LOAD: CUSTOMER
-- ============================================================
INSERT INTO Customer (firstName, lastName, email, address1, address2, birthDate, zip, source_id)
SELECT
    firstName,
    lastName,
    email,
    address1,
    address2,
    STR_TO_DATE(birthDate, '%c/%e/%Y'),
    CAST(zip AS DECIMAL(5,0)),
    customer_id
FROM stg_customer
WHERE status = 'pending';

-- ============================================================
-- LOAD: PRODUCT
-- ============================================================
INSERT INTO Product (name, currentPrice, availableQuantity, source_id)
SELECT
    TRIM(name),
    CAST(currentPrice AS DECIMAL(6,2)),
    CAST(availableQuantity AS UNSIGNED),
    product_id
FROM stg_product
WHERE status = 'pending';

-- ============================================================
-- LOAD: ORDER
-- ============================================================
INSERT INTO `Order` (datePlaced, dateShipped, customer_id, source_id)
SELECT
    o.datePlaced,
    o.dateShipped,
    c.id,
    o.order_id
FROM stg_order o
JOIN Customer c ON c.source_id = o.customer_id
WHERE o.status = 'pending';


-- Add indexes to source_id columns to speed up the JOIN
--Query performance was very slow intiatlly so 
ALTER TABLE `Order` ADD INDEX idx_source_id (source_id);
ALTER TABLE Product ADD INDEX idx_source_id (source_id);


ALTER TABLE stg_orderline ADD INDEX idx_order_id (order_id);
ALTER TABLE stg_orderline ADD INDEX idx_product_id (product_id);

-- ============================================================
-- LOAD: ORDERLINE 
-- 
-- NOTE: LOAD PERFORMANCE DRASTICALLY IMPROVED BY ADDING 
--  INDEXES TO SOURCE_ID COLUMNS AND STAGING
--  TABLE COLUMNS USED IN JOIN CONDITIONS

-- ============================================================
INSERT INTO Orderline (order_id, product_id, quantity)
SELECT
    o.id,
    p.id,
    COUNT(*) AS quantity
FROM stg_orderline sl
JOIN `Order` o ON o.source_id = sl.order_id
JOIN Product p ON p.source_id = sl.product_id
WHERE sl.status = 'pending'
GROUP BY o.id, p.id;

/*

--commenting out so that pricehistory table is not populated automatically
--will only be populated by trigger in M2 project

-- ============================================================
-- LOAD: PRICEHISTORY
-- ============================================================
INSERT INTO PriceHistory (oldPrice, newPrice, ts, product_id)
SELECT
    currentPrice,
    currentPrice,
    NOW(),
    id
FROM Product;
*/

-- ============================================================
-- TEARDOWN BLOCK: DROP source_id and DROP STAGING TABLES
-- ============================================================
ALTER TABLE Customer DROP COLUMN source_id;
ALTER TABLE Product DROP COLUMN source_id;
ALTER TABLE `Order` DROP COLUMN source_id;

DROP TABLE IF EXISTS stg_customer;
DROP TABLE IF EXISTS stg_product;
DROP TABLE IF EXISTS stg_order;
DROP TABLE IF EXISTS stg_orderline;
DROP TABLE IF EXISTS stg_city;
DROP TABLE IF EXISTS stg_pricehistory;


EOF



# Set ownership so nonprivuser owns the file
chown "${USERNAME}:${USERNAME}" /home/${USERNAME}/etl.sql
chmod 640 /home/${USERNAME}/etl.sql

touch /root/9-etl-sql-written

# Auto-execute the SQL file against MariaDB on launch
#mariadb < /home/${USERNAME}/etl.sql
#sudo -u ${USERNAME} mariadb < /home/${USERNAME}/etl.sql

# Execute the ETL SQL file as the MariaDB appuser
#need to remove database from command below
#sudo mariadb --local-infile=1 -u ${USERNAME} -p"${PASSWORD}" < /home/${USERNAME}/etl.sql

sudo su - ${USERNAME} -c "mariadb --local-infile=1 -u ${USERNAME} -p'${PASSWORD}' < /home/${USERNAME}/etl.sql"

touch /root/10-etl-sql-executed

cat > /home/${USERNAME}/views.sql <<'EOF'

USE POS;

-- =========================================
-- VIEW: v_ProductBuyers
-- Lists all customers who purchased each product.
-- LEFT JOIN ensures products with no sales are still included.
-- =========================================
CREATE OR REPLACE VIEW v_ProductBuyers AS
SELECT
    p.id   AS productID,
    p.name AS productName,
    GROUP_CONCAT(
        DISTINCT CONCAT(c.id, ' ', c.firstName, ' ', c.lastName)
        ORDER BY c.id
        SEPARATOR ', '
    ) AS customers
FROM Product p
LEFT JOIN Orderline ol ON p.id = ol.product_id
LEFT JOIN `Order`   o  ON ol.order_id = o.id
LEFT JOIN Customer  c  ON o.customer_id = c.id
GROUP BY p.id, p.name
ORDER BY p.id;


-- =========================================
-- MATERIALIZED VIEW: mv_ProductBuyers
-- Simulated via a physical snapshot table.
-- =========================================
DROP TABLE IF EXISTS mv_ProductBuyers;

CREATE TABLE mv_ProductBuyers AS
SELECT * FROM v_ProductBuyers;

CREATE INDEX idx_productID ON mv_ProductBuyers(productID);

-- =========================================
-- TRIGGERS: Keep mv_ProductBuyers in sync
-- =========================================



DELIMITER $$ 
-- =========================================
--this 'DELIMTER' command is needed to keep mariadb from 
--getting confused by the semicolons in the trigger body
--'BEGIN..END' block previously was 'END;'
--=========================================


-- Fires when a new orderline is inserted
CREATE TRIGGER trg_after_orderline_insert
AFTER INSERT ON Orderline
FOR EACH ROW
BEGIN
    UPDATE mv_ProductBuyers
    SET customers = (
        SELECT GROUP_CONCAT(
                   DISTINCT CONCAT(c.id, ' ', c.firstName, ' ', c.lastName)
                   ORDER BY c.id
                   SEPARATOR ', '
               )
        FROM Orderline ol
        JOIN POS.Order  o ON ol.order_id  = o.id
        JOIN Customer c ON o.customer_id = c.id
        WHERE ol.product_id = NEW.product_id
    )
    WHERE productID = NEW.product_id;
END$$


-- Fires when an orderline is deleted
CREATE TRIGGER trg_after_orderline_delete
AFTER DELETE ON Orderline
FOR EACH ROW
BEGIN
    UPDATE mv_ProductBuyers
    SET customers = (
        SELECT GROUP_CONCAT(
                   DISTINCT CONCAT(c.id, ' ', c.firstName, ' ', c.lastName)
                   ORDER BY c.id
                   SEPARATOR ', '
               )
        FROM Orderline ol
        JOIN `Order`  o ON ol.order_id  = o.id
        JOIN Customer c ON o.customer_id = c.id
        WHERE ol.product_id = OLD.product_id
    )
    WHERE productID = OLD.product_id;
END$$


-- =========================================
-- TRIGGER: Log price changes to PriceHistory
-- =========================================

CREATE TRIGGER trg_after_product_update
AFTER UPDATE ON Product
FOR EACH ROW
BEGIN
    IF OLD.currentPrice <> NEW.currentPrice THEN
        INSERT INTO PriceHistory (oldPrice, newPrice, ts, product_id)
        VALUES (OLD.currentPrice, NEW.currentPrice, NOW(), NEW.id);
    END IF;
END$$

EOF

touch /root/11-views-sql-written

# Set ownership so nonprivuser owns the file
chown "${USERNAME}:${USERNAME}" /home/${USERNAME}/views.sql
chmod 640 /home/${USERNAME}/views.sql

#sudo mariadb --local-infile=1 -u ${USERNAME} -p"${PASSWORD}" < /home/${USERNAME}/views.sql

sudo su - ${USERNAME} -c "mariadb --local-infile=1 -u ${USERNAME} -p'${PASSWORD}' < /home/${USERNAME}/views.sql"

touch /root/12-views-sql-executed

# -------------------------------------------------------
# CREATE .JSON files
# 
# 
# -------------------------------------------------------

# Create mysql-files directory to hold .json files
sudo mkdir /var/lib/mysql-files/

#allows mariadb to write to the directory
sudo chown mysql:mysql /var/lib/mysql-files/
sudo chmod 750 /var/lib/mysql-files/

cat > /home/${USERNAME}/xjson.sql <<'EOF'

-- =========================================
-- build prod.json file
-- =========================================

USE POS;

SELECT JSON_OBJECT(
    'ProductID',    p.id,
    'currentPrice', p.currentPrice,
    'productName',  p.name,
    'customers',    COALESCE(
        (SELECT JSON_ARRAYAGG(
            JSON_OBJECT(
                'CustomerID',   c.id,
                'CustomerName', CONCAT(c.firstName, ' ', c.lastName)
            )
        )
        FROM Orderline ol
        JOIN `Order` o  ON ol.order_id  = o.id
        JOIN Customer c ON o.customer_id = c.id
        WHERE ol.product_id = p.id
        ),
        JSON_ARRAY()
    )
)
FROM Product p
INTO OUTFILE '/var/lib/mysql-files/prod.json';

-- =========================================
-- build cust.json file
-- =========================================

-- CTE 1: Build the Items array and order total per order
WITH order_items AS (
    SELECT
        ol.order_id,
        SUM(ol.quantity * p.currentPrice) AS order_total,
        JSON_ARRAYAGG(
            JSON_OBJECT(
                'ProductID',   p.id,
                'Quantity',    ol.quantity,
                'ProductName', p.name
            )
        ) AS items
    FROM Orderline ol
    JOIN Product p ON ol.product_id = p.id
    GROUP BY ol.order_id
),

-- CTE 2: Wrap items into the Orders array per customer
customer_orders AS (
    SELECT
        o.customer_id,
        JSON_ARRAYAGG(
            JSON_OBJECT(
                'OrderTotal',   oi.order_total,
                'OrderDate',    o.datePlaced,
                'ShippingDate', o.dateShipped,
                'Items',        oi.items
            )
        ) AS orders
    FROM `Order` o
    JOIN order_items oi ON o.id = oi.order_id
    GROUP BY o.customer_id
)

-- Final: Build the root Customer object
SELECT JSON_OBJECT(
    'customer_name',      CONCAT(c.firstName, ' ', c.lastName),
    'printed_address_1',  CASE
                              WHEN c.address2 IS NOT NULL AND c.address2 != ''
                              THEN CONCAT(c.address1, ' #', c.address2)
                              ELSE c.address1
                          END,
    'printed_address_2',  CONCAT(ct.city, ', ', ct.state, '   ', ct.zip),
    'orders',             COALESCE(co.orders, JSON_ARRAY())
)
FROM Customer c
LEFT JOIN City ct             ON c.zip = ct.zip
LEFT JOIN customer_orders co  ON c.id  = co.customer_id
INTO OUTFILE '/var/lib/mysql-files/cust.json';


-- =========================================
-- create custom1.json custom case #1
-- =========================================

WITH region_product_stats AS (
    SELECT
        c.zip,
        p.id    AS product_id,
        p.name  AS product_name,
        SUM(ol.quantity)                AS total_qty,
        SUM(ol.quantity * p.currentPrice) AS revenue
    FROM Customer c
    JOIN `Order` o    ON o.customer_id  = c.id
    JOIN Orderline ol ON ol.order_id    = o.id
    JOIN Product p    ON ol.product_id  = p.id
    GROUP BY c.zip, p.id, p.name
),

region_products AS (
    SELECT
        zip,
        SUM(total_qty) AS total_units_sold,
        SUM(revenue)   AS total_revenue,
        JSON_ARRAYAGG(
            JSON_OBJECT(
                'ProductID',    product_id,
                'ProductName',  product_name,
                'QuantitySold', total_qty,
                'Revenue',      revenue
            )
        ) AS products
    FROM region_product_stats
    GROUP BY zip
),

region_customers AS (
    SELECT
        c.zip,
        JSON_ARRAYAGG(
            JSON_OBJECT(
                'CustomerID',   c.id,
                'CustomerName', CONCAT(c.firstName, ' ', c.lastName)
            )
        ) AS customers
    FROM Customer c
    GROUP BY c.zip
)

SELECT JSON_OBJECT(
    'city',             ct.city,
    'state',            ct.state,
    'zip',              ct.zip,
    'total_revenue',    COALESCE(rp.total_revenue, 0),
    'total_units_sold', COALESCE(rp.total_units_sold, 0),
    'customer_count',   (SELECT COUNT(*) FROM Customer c2 WHERE c2.zip = ct.zip),
    'products_sold',    COALESCE(rp.products, JSON_ARRAY()),
    'customers',        COALESCE(rc.customers, JSON_ARRAY())
)
FROM City ct
LEFT JOIN region_products rp  ON ct.zip = rp.zip
LEFT JOIN region_customers rc ON ct.zip = rc.zip
INTO OUTFILE '/var/lib/mysql-files/custom1.json';


-- =========================================
-- create custom2.json custom case #2
-- =========================================

WITH customer_product_stats AS (
    SELECT
        o.customer_id,
        p.id    AS product_id,
        p.name  AS product_name,
        SUM(ol.quantity)                  AS total_qty,
        SUM(ol.quantity * p.currentPrice) AS total_spent
    FROM `Order` o
    JOIN Orderline ol ON ol.order_id   = o.id
    JOIN Product p    ON ol.product_id = p.id
    GROUP BY o.customer_id, p.id, p.name
),

customer_products AS (
    SELECT
        customer_id,
        JSON_ARRAYAGG(
            JSON_OBJECT(
                'ProductID',     product_id,
                'ProductName',   product_name,
                'TotalQuantity', total_qty,
                'TotalSpent',    total_spent
            )
        ) AS products_purchased
    FROM customer_product_stats
    GROUP BY customer_id
),

customer_spend AS (
    SELECT
        o.customer_id,
        COUNT(DISTINCT o.id)              AS order_count,
        SUM(ol.quantity * p.currentPrice) AS lifetime_spend
    FROM `Order` o
    JOIN Orderline ol ON ol.order_id   = o.id
    JOIN Product p    ON ol.product_id = p.id
    GROUP BY o.customer_id
)

SELECT JSON_OBJECT(
    'CustomerID',          c.id,
    'customer_name',       CONCAT(c.firstName, ' ', c.lastName),
    'email',               c.email,
    'lifetime_spend',      COALESCE(cs.lifetime_spend, 0),
    'order_count',         COALESCE(cs.order_count, 0),
    'avg_order_value',     COALESCE(ROUND(cs.lifetime_spend / cs.order_count, 2), 0),
    'products_purchased',  COALESCE(cp.products_purchased, JSON_ARRAY())
)
FROM Customer c
LEFT JOIN customer_spend cs    ON c.id = cs.customer_id
LEFT JOIN customer_products cp ON c.id = cp.customer_id
INTO OUTFILE '/var/lib/mysql-files/custom2.json';

EOF

sudo su - ${USERNAME} -c "mariadb --local-infile=1 -u ${USERNAME} -p'${PASSWORD}' < /home/${USERNAME}/xjson.sql"
