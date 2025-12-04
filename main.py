import psycopg2
from flask import Flask, render_template, request, redirect, url_for, g, flash, current_app
from psycopg2.extras import RealDictCursor
import pytz
from datetime import datetime
import random

app = Flask(__name__)
app.secret_key = "supersecretkey"
def get_db():
    if 'db' not in g:
        g.db = psycopg2.connect(
            host="localhost",
            database="practice",
            user="postgres",
            password="987055az",
            cursor_factory = RealDictCursor,
        )
    return g.db

@app.teardown_appcontext
def close_db(error):
     db = g.pop('db', None)
     if db is not None:
      db.close()
#-------------------------Routing----------------------
@app.route('/')
def home():
 return render_template('home.html')

@app.route('/shop')
def shop():
  conn = get_db()
  cur = conn.cursor()
  cur.execute("SELECT * FROM products ORDER BY id")
  items = cur.fetchall()
  return render_template('shop.html', items=items)

@app.route('/buy/<int:product_id>', methods=['POST'])
def buy(product_id):
  conn = get_db()
  cur = conn.cursor()
  cur.execute("SELECT id, name, price, quantity FROM products WHERE id=%s", (product_id,))
  item = cur.fetchone()
  if item['quantity'] <= 0:
    flash("Товар розпродано!", "error")
    return redirect(url_for('shop'))
  cur.execute("UPDATE products SET quantity = quantity - 1 WHERE id=%s", (product_id,))
  conn.commit()
  flash(f"Ви успішно купили: {item['name']}", "success")
  return redirect(url_for('shop'))

@app.route("/testyourself")
def test_yourself():
    answers = ["Serhii", "Rabchun", "ISD31"]
    return random.choice(answers)

@app.route("/random_number")
def random_number():
    n = random.randint(1, 10)
    return render_template("random.html", number=n)

@app.cli.command("init")
def init_db():
    conn = get_db()
    cur = conn.cursor()
    with current_app.open_resource("schema.sql") as file:
        alltext = file.read()
        cur.execute(alltext)
    conn.commit()
    print("Initialized the database and cleared tables.")


@app.cli.command('populate')
def populate_db():
    conn = get_db()
    cur = conn.cursor()

    with current_app.open_resource("populate.sql") as file:
        sql = file.read().decode("utf-8")
        cur.execute(sql)

    conn.commit()
    print("Populated database with sample data.")

def debug(msg):
    from flask import current_app
    current_app.logger.debug(msg)

@app.route("/dump")
def dump_entries():
    conn = get_db()
    cursor = conn.cursor()
    cursor.execute('select id, date, title, content from entries order by date')
    rows = cursor.fetchall()
    output = ""
    for r in rows:
        debug(str(r))
        output += str(r) + "\n"
    return "Should see database dump here:\n<pre>" + output + "</pre>"

@app.route("/browse")
def browse():
    conn = get_db()
    cursor = conn.cursor()
    cursor.execute('select id, date, title, content from entries order by date')
    rowlist = cursor.fetchall()
    return render_template('browse.html', entries=rowlist)


@app.route('/admin')
def admin_panel():
    """Адмін-панель з статистикою"""
    conn = get_db()
    cur = conn.cursor()

    # Статистика продажів
    cur.execute("SELECT * FROM get_sales_stats(30)")
    sales_stats = cur.fetchall()

    # Топ товарів
    cur.execute("SELECT * FROM get_top_products(5)")
    top_products = cur.fetchall()

    # Сповіщення про низькі залишки
    cur.execute("SELECT * FROM low_stock_alerts WHERE is_resolved = FALSE ORDER BY alert_date DESC")
    low_stock = cur.fetchall()

    # Історія цін (останні 10)
    cur.execute("""
        SELECT ph.*, p.name 
        FROM price_history ph
        JOIN products p ON ph.product_id = p.id
        ORDER BY ph.changed_at DESC 
        LIMIT 10
    """)
    price_history = cur.fetchall()

    return render_template('admin.html',
                           sales_stats=sales_stats,
                           top_products=top_products,
                           low_stock=low_stock,
                           price_history=price_history)


@app.route('/admin/restock/<int:product_id>', methods=['POST'])
def restock(product_id):
    """Поповнення товару"""
    quantity = request.form.get('quantity', type=int)

    if not quantity or quantity <= 0:
        flash("Введіть коректну кількість!", "error")
        return redirect(url_for('admin_panel'))

    conn = get_db()
    cur = conn.cursor()

    try:
        cur.execute("SELECT restock_product(%s, %s)", (product_id, quantity))
        result = cur.fetchone()
        conn.commit()

        # Правильний виклик flash - беремо результат з dict
        if result:
            flash(str(result['restock_product']), "success")
        else:
            flash("Товар успішно поповнено!", "success")
    except Exception as e:
        conn.rollback()
        flash(f"Помилка: {str(e)}", "error")

    return redirect(url_for('admin_panel'))


@app.route('/admin/discount/<int:product_id>', methods=['POST'])
def apply_discount_route(product_id):
    """Застосування знижки"""
    discount = request.form.get('discount', type=float)
    
    if not discount or discount <= 0 or discount > 100:
        flash("Знижка має бути від 1% до 100%!", "error")
        return redirect(url_for('admin_panel'))
    
    conn = get_db()
    cur = conn.cursor()
    
    try:
        cur.execute("SELECT apply_discount(%s, %s)", (product_id, discount))
        result = cur.fetchone()
        conn.commit()
        
        # Правильний виклик flash - беремо результат з dict
        if result:
            flash(str(result['apply_discount']), "success")
        else:
            flash("Знижку застосовано!", "success")
    except Exception as e:
        conn.rollback()
        flash(f"Помилка: {str(e)}", "error")
    
    return redirect(url_for('admin_panel'))

@app.route('/admin/sales-log')
def sales_log():
    conn = get_db()
    cur = conn.cursor()

    cur.execute("""
        SELECT * FROM sales_log 
        ORDER BY sale_date DESC 
        LIMIT 100
    """)
    logs = cur.fetchall()

    return render_template('sales_log.html', logs=logs)
@app.cli.command('triggers')
def triggers_db():
    conn = get_db()
    cur = conn.cursor()

    with current_app.open_resource("triggers_and_procedures.sql") as file:
        sql = file.read().decode("utf-8")
        cur.execute(sql)

    conn.commit()
    print("Triggered database")

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=8080)

