# -*- coding: utf-8 -*-
import os, random, time, sys, socket, hashlib
from datetime import datetime, timedelta
from contextlib import contextmanager
from functools import wraps
from flask import Flask, render_template, request, redirect, url_for, flash, session
from werkzeug.utils import secure_filename
import psycopg2
from psycopg2 import IntegrityError
from psycopg2.extras import RealDictCursor

# ===== Sortie console UTF-8 (Windows) =====
try:
    sys.stdout.reconfigure(encoding="utf-8")
    sys.stderr.reconfigure(encoding="utf-8")
except Exception:
    pass

# ===== Flask =====
BASE = os.path.dirname(os.path.abspath(__file__))
app = Flask(__name__, template_folder=os.path.join(BASE, "templates"),
             static_folder=os.path.join(BASE, "static"))
app.secret_key = "change-this-secret"
app.config['MAX_CONTENT_LENGTH'] = 100 * 1024 * 1024  # 100 MB

# Dossiers dâ€™upload
UP = os.path.join(BASE, "static", "uploads")
PAY_DIR = os.path.join(UP, "payments")
VID_DIR = os.path.join(UP, "videos")
PDF_DIR = os.path.join(UP, "pdfs")
for p in (PAY_DIR, VID_DIR, PDF_DIR):
    os.makedirs(p, exist_ok=True)

IMG_EXT   = {"jpg","jpeg","png","webp","pdf"}  # payment proof allows pdf too
VIDEO_EXT = {"mp4","webm","mkv","avi","mov","ogg"}
PDF_EXT   = {"pdf"}
def allowed(fn, exts): return "." in fn and fn.rsplit(".",1)[1].lower() in exts

# ===== PostgreSQL =====
DATABASE_URL = os.getenv("DATABASE_URL")
DB = dict(
    host=os.getenv("PGHOST", "localhost"),
    port=os.getenv("PGPORT", "5432"),
    user=os.getenv("PGUSER", "postgres"),
    password=os.getenv("PGPASSWORD", ""),
    dbname=os.getenv("PGDATABASE", "school_app"),
)

@contextmanager
def db():
    conn = psycopg2.connect(DATABASE_URL) if DATABASE_URL else psycopg2.connect(**DB)
    try:
        yield conn
    finally:
        conn.close()

def dict_cursor(conn):
    return conn.cursor(cursor_factory=RealDictCursor)

def hash_password(password: str) -> str:
    return hashlib.sha256(password.encode("utf-8")).hexdigest()

# ===== SMS (Twilio ou mode DEV) =====
TWILIO_SID   = os.getenv("TWILIO_ACCOUNT_SID")
TWILIO_TOKEN = os.getenv("TWILIO_AUTH_TOKEN")
TWILIO_FROM  = os.getenv("TWILIO_FROM_NUMBER")
DEV_SMS      = not (TWILIO_SID and TWILIO_TOKEN and TWILIO_FROM)

def send_sms(phone: str, message: str):
    """
    En DEV on imprime une version ASCII-safe (pas d'accents) pour Ã©viter UnicodeEncodeError,
    et on affiche le texte FR via flash.
    """
    if DEV_SMS:
        import re
        m = re.search(r"(\d{4,6})", message)
        code = m.group(1) if m else "xxxxxx"
        print(f"[DEV SMS] to {phone}: code={code}")  # ASCII only
        try:
            flash(f"(DEV) Code envoyÃ© au {phone} : {code}", "secondary")
        except Exception:
            pass
        return True
    try:
        from twilio.rest import Client
        Client(TWILIO_SID, TWILIO_TOKEN).messages.create(to=phone, from_=TWILIO_FROM, body=message)
        return True
    except Exception as e:
        print("SMS error:", e)
        flash("Ã‰chec dâ€™envoi du SMS. VÃ©rifiez la configuration Twilio.", "danger")
        return False

# ===== OTP =====
def create_otp(phone: str, purpose: str) -> str:
    code = f"{random.randint(100000, 999999)}"
    expires_at = (datetime.utcnow() + timedelta(minutes=10)).strftime("%Y-%m-%d %H:%M:%S")
    with db() as conn:
        cur = conn.cursor()
        cur.execute("""INSERT INTO verification_codes (phone, code, purpose, expires_at)
                       VALUES (%s,%s,%s,%s)""", (phone, code, purpose, expires_at))
        conn.commit(); cur.close()
    return code

def verify_otp(phone: str, purpose: str, code: str) -> bool:
    with db() as conn:
        cur = dict_cursor(conn)
        cur.execute("""SELECT id FROM verification_codes
                       WHERE phone=%s AND purpose=%s AND code=%s
                         AND used=FALSE AND expires_at>CURRENT_TIMESTAMP
                       ORDER BY id DESC LIMIT 1""", (phone, purpose, code))
        row = cur.fetchone()
        if not row:
            cur.close(); return False
        cur2 = conn.cursor()
        cur2.execute("UPDATE verification_codes SET used=TRUE WHERE id=%s", (row["id"],))
        conn.commit(); cur2.close(); cur.close()
    return True

# ===== Auth =====
def login_required(role=None):
    def deco(fn):
        @wraps(fn)
        def wrap(*a, **kw):
            if "user_id" not in session:
                return redirect(url_for("login"))
            if role and session.get("role") != role:
                flash("Vous nâ€™avez pas lâ€™autorisation.", "danger")
                return redirect(url_for("home"))
            return fn(*a, **kw)
        return wrap
    return deco

# ===== Routes =====
@app.route("/")
def home():
    if "user_id" in session:
        r = session["role"]
        return redirect(url_for("admin_dashboard" if r=="admin" else
                                "teacher_dashboard" if r=="teacher" else
                                "student_dashboard"))
    return render_template("home.html")

@app.route("/about")
def about():
    return render_template("about.html")

@app.route("/privacy")
def privacy():
    return render_template("privacy.html")

@app.route("/contact")
def contact():
    return render_template("contact.html")

@app.route("/login", methods=["GET","POST"])
def login():
    if request.method == "GET":
        if "user_id" in session:
            return redirect(url_for("home"))
        return render_template("login.html")

    username = request.form.get("username","").strip()
    password = request.form.get("password","")
    with db() as conn:
        cur = dict_cursor(conn)
        cur.execute("SELECT * FROM users WHERE username=%s AND password=%s",
                    (username, hash_password(password)))
        u = cur.fetchone(); cur.close()
    if not u:
        flash("Identifiants incorrects.", "danger"); return redirect(url_for("login"))
    if u["phone_verified"] != 1:
        code = create_otp(u["phone"], "register")
        send_sms(u["phone"], f"Votre code de vÃ©rification est : {code}")
        session["pending_phone"] = u["phone"]
        flash("Vous devez dâ€™abord valider votre numÃ©ro de tÃ©lÃ©phone.", "warning")
        return redirect(url_for("verify_phone"))
    if u["status"] != "active":
        flash("Compte en attente dâ€™approbation par lâ€™administrateur.", "warning"); return redirect(url_for("login"))
    session.update(user_id=u["id"], role=u["role"], level=u["level"], subject=u.get("subject"))
    return redirect(url_for("home"))

@app.route("/logout")
def logout():
    session.clear(); return redirect(url_for("home"))

# --- Inscription Ã©tudiant: donnÃ©es de base Ø«Ù… onboarding Ø«Ù… paiement
@app.route("/register", methods=["GET","POST"])
def register():
    if request.method == "POST":
        username = request.form.get("username","").strip()
        phone    = request.form.get("phone","").strip()
        password = request.form.get("password","")
        confirm  = request.form.get("confirm_password","")

        if not username or not phone or not password or not confirm:
            flash("Veuillez complÃ©ter tous les champs.", "danger"); return redirect(url_for("register"))
        if password != confirm:
            flash("Le code et sa confirmation ne correspondent pas.", "danger"); return redirect(url_for("register"))

        session["pending_registration"] = {
            "username": username,
            "phone": phone,
            "password": password,
        }
        return redirect(url_for("courses"))
    return render_template("register.html")

COURSES = [
    {
        "code": "MPI",
        "title": "MPI",
        "subtitle": "Ø§Ù„Ø±ÙŠØ§Ø¶ÙŠØ§ØªØŒ Ø§Ù„ÙÙŠØ²ÙŠØ§Ø¡ ÙˆØ§Ù„Ø¥Ø¹Ù„Ø§Ù…ÙŠØ©",
        "description": "Ø¯Ø±ÙˆØ³ Ù…Ø±ÙƒØ²Ø© ÙˆØªÙ…Ø§Ø±ÙŠÙ† Ù…Ø­Ù„ÙˆÙ„Ø© Ù„Ù„ØªØ­Ø¶ÙŠØ± Ø¨Ø«Ù‚Ø©.",
        "badge": "Ù…ØªØ§Ø­",
        "icon": "ðŸ§®",
        "theme": "blue",
    },
    {
        "code": "PC",
        "title": "PC",
        "subtitle": "Ø§Ù„ÙÙŠØ²ÙŠØ§Ø¡ ÙˆØ§Ù„ÙƒÙŠÙ…ÙŠØ§Ø¡",
        "description": "Ø´Ø±Ø­ Ù…Ø¨Ø³Ø· Ù„Ù„ØªØ¬Ø§Ø±Ø¨ ÙˆØ§Ù„Ù‚ÙˆØ§Ù†ÙŠÙ† ÙˆØ§Ù„ØªÙ…Ø§Ø±ÙŠÙ†.",
        "badge": "Ù…ØªØ§Ø­",
        "icon": "âš—",
        "theme": "green",
    },
    {
        "code": "BG",
        "title": "BG",
        "subtitle": "Ø¹Ù„ÙˆÙ… Ø§Ù„Ø­ÙŠØ§Ø© ÙˆØ§Ù„Ø£Ø±Ø¶",
        "description": "Ù…Ù„Ø®ØµØ§Øª Ù…Ù†Ø¸Ù…Ø© ÙˆØ±Ø³ÙˆÙ… ØªÙˆØ¶ÙŠØ­ÙŠØ© Ù„Ù„Ù…Ø±Ø§Ø¬Ø¹Ø©.",
        "badge": "Ù…ØªØ§Ø­",
        "icon": "ðŸ§¬",
        "theme": "purple",
    },
    {
        "code": "BAC",
        "title": "BAC",
        "subtitle": "Ø¨Ø§ÙƒØ§Ù„ÙˆØ±ÙŠØ§",
        "description": "Ø¨Ø±Ù†Ø§Ù…Ø¬ Ù…Ø±Ø§Ø¬Ø¹Ø© Ø´Ø§Ù…Ù„ Ù„Ø§Ø¬ØªÙŠØ§Ø² Ø§Ù„Ø§Ù…ØªØ­Ø§Ù†.",
        "badge": "Ù‚Ø±ÙŠØ¨Ø§",
        "icon": "ðŸŽ“",
        "theme": "orange",
    },
    {
        "code": "BREVET",
        "title": "BREVET",
        "subtitle": "Ø´Ù‡Ø§Ø¯Ø© Ø®ØªÙ… Ø§Ù„Ø¯Ø±ÙˆØ³ Ø§Ù„Ø¥Ø¹Ø¯Ø§Ø¯ÙŠØ©",
        "description": "Ø¯Ø±ÙˆØ³ ÙˆØªØ·Ø¨ÙŠÙ‚Ø§Øª Ø­Ø³Ø¨ Ø§Ù„Ø¨Ø±Ù†Ø§Ù…Ø¬.",
        "badge": "Ù‚Ø±ÙŠØ¨Ø§",
        "icon": "ðŸ“˜",
        "theme": "cyan",
    },
    {
        "code": "DESIGN",
        "title": "ØªØµÙ…ÙŠÙ… Ø¬Ø±Ø§ÙÙŠÙƒ",
        "subtitle": "ØªØ¹Ù„Ù… Ø§Ù„ØªØµÙ…ÙŠÙ… Ù…Ù† Ø§Ù„ØµÙØ±",
        "description": "Ø£Ø³Ø§Ø³ÙŠØ§Øª Ø§Ù„ØªØµÙ…ÙŠÙ… ÙˆØ£Ø¯ÙˆØ§Øª Ø§Ù„Ø¹Ù…Ù„.",
        "badge": "Ù‚Ø±ÙŠØ¨Ø§",
        "icon": "ðŸŽ¨",
        "theme": "pink",
    },
    {
        "code": "AI",
        "title": "Ø°ÙƒØ§Ø¡ Ø§ØµØ·Ù†Ø§Ø¹ÙŠ",
        "subtitle": "Ù…Ø¨Ø§Ø¯Ø¦ Ø§Ù„Ø°ÙƒØ§Ø¡ Ø§Ù„Ø§ØµØ·Ù†Ø§Ø¹ÙŠ",
        "description": "ØªØ¹Ù„Ù… Ø§Ù„Ù…ÙØ§Ù‡ÙŠÙ… Ø§Ù„Ø£Ø³Ø§Ø³ÙŠØ© ÙˆØ§Ù„ØªØ·Ø¨ÙŠÙ‚Ø§Øª.",
        "badge": "Ù‚Ø±ÙŠØ¨Ø§",
        "icon": "ðŸ¤–",
        "theme": "indigo",
    },
]

def ensure_courses_table():
    with db() as conn:
        cur = conn.cursor()
        cur.execute("SELECT to_regclass('public.courses')")
        table_exists = cur.fetchone()[0] is not None
        cur.execute("ALTER TABLE users ADD COLUMN IF NOT EXISTS subject VARCHAR(80)")
        cur.execute("""
            CREATE TABLE IF NOT EXISTS courses (
                id SERIAL PRIMARY KEY,
                code VARCHAR(40) NOT NULL UNIQUE,
                title VARCHAR(100) NOT NULL,
                subtitle VARCHAR(255) NOT NULL DEFAULT '',
                description TEXT,
                badge VARCHAR(40) DEFAULT '',
                icon VARCHAR(20) DEFAULT 'ðŸ“˜',
                theme VARCHAR(30) DEFAULT 'blue',
                sort_order INT DEFAULT 0,
                active BOOLEAN DEFAULT TRUE,
                created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
            )
        """)
        cur.execute("""
            CREATE TABLE IF NOT EXISTS course_subjects (
                id SERIAL PRIMARY KEY,
                course_code VARCHAR(40) NOT NULL REFERENCES courses(code) ON DELETE CASCADE,
                subject VARCHAR(80) NOT NULL,
                sort_order INT DEFAULT 0,
                created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                UNIQUE (course_code, subject)
            )
        """)
        if not table_exists:
            for index, course in enumerate(COURSES, start=1):
                cur.execute("""
                    INSERT INTO courses
                        (code, title, subtitle, description, badge, icon, theme, sort_order, active)
                    VALUES (%s,%s,%s,%s,%s,%s,%s,%s,TRUE)
                """, (
                    course["code"], course["title"], course["subtitle"], course["description"],
                    course["badge"], course["icon"], course["theme"], index
                ))
        cur.execute("SELECT COUNT(*) FROM course_subjects")
        if cur.fetchone()[0] == 0:
            default_subjects = ["Math", "Physique", "Chimie", "Science naturelle"]
            cur.execute("SELECT code FROM courses ORDER BY sort_order ASC, id ASC")
            existing_courses = [row[0] for row in cur.fetchall()]
            for course_code in existing_courses:
                for index, subject in enumerate(default_subjects, start=1):
                    cur.execute("""
                        INSERT INTO course_subjects (course_code, subject, sort_order)
                        VALUES (%s,%s,%s)
                        ON CONFLICT (course_code, subject) DO NOTHING
                    """, (course_code, subject, index))
        conn.commit()
        cur.close()

def fetch_courses(active_only=True):
    ensure_courses_table()
    with db() as conn:
        cur = dict_cursor(conn)
        where = "WHERE active=TRUE" if active_only else ""
        cur.execute(f"""SELECT id, code, title, subtitle, description, badge, icon, theme, sort_order, active
                        FROM courses {where}
                        ORDER BY sort_order ASC, id ASC""")
        rows = cur.fetchall()
        cur.close()
    return rows

def fetch_course_subjects(course_code=None):
    ensure_courses_table()
    with db() as conn:
        cur = dict_cursor(conn)
        if course_code:
            cur.execute("""SELECT id, course_code, subject, sort_order
                           FROM course_subjects
                           WHERE course_code=%s
                           ORDER BY sort_order ASC, id ASC""", (course_code,))
        else:
            cur.execute("""SELECT id, course_code, subject, sort_order
                           FROM course_subjects
                           ORDER BY course_code ASC, sort_order ASC, id ASC""")
        rows = cur.fetchall()
        cur.close()
    return rows

@app.route("/courses", methods=["GET","POST"])
def courses():
    pending = session.get("pending_registration")
    if not pending:
        return redirect(url_for("register"))
    available_courses = fetch_courses(active_only=True)
    if request.method == "POST":
        selected = request.form.get("course")
        course = next((c for c in available_courses if c["code"] == selected), None)
        if not course:
            flash("Veuillez choisir une formation.", "danger")
            return redirect(url_for("courses"))
        pending["level"] = course["code"]
        pending["course_title"] = course["title"]
        session["pending_registration"] = pending
        return redirect(url_for("onboarding"))
    return render_template("courses.html", courses=available_courses)

@app.route("/onboarding")
def onboarding():
    if "pending_registration" not in session:
        return redirect(url_for("register"))
    return render_template("onboarding.html")

@app.route("/payment", methods=["GET","POST"])
def payment():
    pending = session.get("pending_registration")
    if not pending:
        return redirect(url_for("register"))
    if request.method == "POST":
        pfile = request.files.get("payment_image")
        if not pfile or pfile.filename == "":
            flash("Merci de tÃ©lÃ©charger lâ€™attestation de paiement.", "warning")
            return redirect(url_for("payment"))
        if not allowed(pfile.filename, IMG_EXT):
            flash("Fichier non autorisÃ© (jpg/png/webp/pdf).", "danger")
            return redirect(url_for("payment"))

        username = pending["username"]
        phone = pending["phone"]
        password = pending["password"]
        level = pending.get("level", "4as")

        base = secure_filename(pfile.filename)
        fname = f"{username}_{int(time.time())}_{base}"
        pfile.save(os.path.join(PAY_DIR, fname))

        try:
            with db() as conn:
                cur = conn.cursor()
                cur.execute("""INSERT INTO users (username, phone, password, role, level, status, phone_verified, payment_image)
                               VALUES (%s,%s,%s,'student',%s,'pending',TRUE,%s)""",
                            (username, phone, hash_password(password), level, fname))
                conn.commit()
                cur.close()
            session.pop("pending_registration", None)
            flash("Votre compte a Ã©tÃ© crÃ©Ã©. Il attend lâ€™approbation de lâ€™administrateur.", "success")
            return redirect(url_for("home"))
        except IntegrityError as e:
            msg = "Nom dâ€™utilisateur dÃ©jÃ  utilisÃ©."
            if "phone" in str(e):
                msg = "NumÃ©ro de tÃ©lÃ©phone dÃ©jÃ  utilisÃ©."
            flash(msg, "danger")
            return redirect(url_for("payment"))
    return render_template("payment.html")

# --- Saisie du code OTP (vÃ©rification du tÃ©lÃ©phone)
@app.route("/verify", methods=["GET","POST"])
def verify_phone():
    phone = session.get("pending_phone","")
    if request.method == "POST":
        code = request.form.get("otp","").strip()
        phone_form = request.form.get("phone","").strip()
        if phone_form: phone = phone_form
        if not phone or not code:
            flash("Le numÃ©ro et le code sont requis.", "danger"); return redirect(url_for("verify_phone"))
        if verify_otp(phone, "register", code):
            with db() as conn:
                cur = conn.cursor()
                cur.execute("UPDATE users SET phone_verified=TRUE WHERE phone=%s", (phone,))
                conn.commit(); cur.close()
            session.pop("pending_phone", None)
            flash("NumÃ©ro vÃ©rifiÃ©. Votre compte attend lâ€™approbation de lâ€™administrateur.", "success")
            return redirect(url_for("home"))
        else:
            flash("Code invalide ou expirÃ©.", "danger")
    return render_template("verify.html", phone=phone)

# --- Mot de passe oubliÃ©
@app.route("/forgot", methods=["GET","POST"])
def forgot():
    if request.method == "POST":
        phone = request.form.get("phone","").strip()
        with db() as conn:
            cur = dict_cursor(conn)
            cur.execute("SELECT id FROM users WHERE phone=%s", (phone,))
            u = cur.fetchone(); cur.close()
        if not u:
            flash("Aucun compte liÃ© Ã  ce numÃ©ro.", "danger"); return redirect(url_for("forgot"))
        code = create_otp(phone, "reset")
        send_sms(phone, f"Code de rÃ©initialisation : {code}")
        session["reset_phone"] = phone
        flash("Un code de rÃ©initialisation a Ã©tÃ© envoyÃ© par SMS.", "success")
        return redirect(url_for("reset_verify"))
    return render_template("forgot.html")

@app.route("/reset-verify", methods=["GET","POST"])
def reset_verify():
    phone = session.get("reset_phone","")
    if request.method == "POST":
        code = request.form.get("code","").strip()
        newp = request.form.get("new_password","")
        phone_form = request.form.get("phone","").strip()
        if phone_form: phone = phone_form
        if not phone or not code or not newp:
            flash("Tous les champs sont requis.", "danger"); return redirect(url_for("reset_verify"))
        if verify_otp(phone, "reset", code):
            with db() as conn:
                cur = conn.cursor()
                cur.execute("UPDATE users SET password=%s WHERE phone=%s", (hash_password(newp), phone))
                conn.commit(); cur.close()
            session.pop("reset_phone", None)
            flash("Mot de passe rÃ©initialisÃ©. Vous pouvez vous connecter.", "success")
            return redirect(url_for("home"))
        else:
            flash("Code invalide ou expirÃ©.", "danger")
    return render_template("reset_verify.html", phone=phone)

# ===== Tableau de bord Admin =====
@app.route("/admin")
@login_required("admin")
def admin_dashboard():
    with db() as conn:
        cur = dict_cursor(conn)
        cur.execute("""SELECT id,username,phone,role,level,subject,status,phone_verified,payment_image
                       FROM users ORDER BY id DESC""")
        users = cur.fetchall(); cur.close()
    courses = fetch_courses(active_only=False)
    course_subjects = fetch_course_subjects()
    return render_template("admin.html", users=users, courses=courses, course_subjects=course_subjects)

@app.route("/admin/activate/<int:uid>")
@login_required("admin")
def activate_user(uid):
    with db() as conn:
        cur = conn.cursor(); cur.execute("UPDATE users SET status='active' WHERE id=%s", (uid,))
        conn.commit(); cur.close()
    flash("Compte activÃ©.", "success"); return redirect(url_for("admin_dashboard"))

@app.route("/admin/delete/<int:uid>")
@login_required("admin")
def delete_user(uid):
    with db() as conn:
        cur = conn.cursor(); cur.execute("DELETE FROM users WHERE id=%s", (uid,))
        conn.commit(); cur.close()
    flash("Compte supprimÃ©.", "warning"); return redirect(url_for("admin_dashboard"))

@app.route("/admin/courses/create", methods=["POST"])
@login_required("admin")
def admin_create_course():
    code = request.form.get("code","").strip().upper()
    title = request.form.get("title","").strip()
    subtitle = request.form.get("subtitle","").strip()
    description = request.form.get("description","").strip()
    badge = request.form.get("badge","").strip()
    icon = request.form.get("icon","").strip() or "ðŸ“˜"
    theme = request.form.get("theme","blue").strip() or "blue"
    sort_order = request.form.get("sort_order","0").strip()

    if not code or not title:
        flash("Le code et le titre de la formation sont requis.", "danger")
        return redirect(url_for("admin_dashboard"))
    try:
        sort_order = int(sort_order)
    except ValueError:
        sort_order = 0

    try:
        ensure_courses_table()
        with db() as conn:
            cur = conn.cursor()
            cur.execute("""
                INSERT INTO courses (code, title, subtitle, description, badge, icon, theme, sort_order, active)
                VALUES (%s,%s,%s,%s,%s,%s,%s,%s,TRUE)
            """, (code, title, subtitle, description, badge, icon, theme, sort_order))
            conn.commit(); cur.close()
        flash("Formation ajoutÃ©e.", "success")
    except IntegrityError:
        flash("Ce code de formation existe dÃ©jÃ .", "danger")
    return redirect(url_for("admin_dashboard"))

@app.route("/admin/courses/subjects/create", methods=["POST"])
@login_required("admin")
def admin_create_course_subject():
    course_code = request.form.get("course_code","").strip()
    subject = request.form.get("subject","").strip()
    sort_order = request.form.get("sort_order","0").strip()
    if not course_code or not subject:
        flash("La formation et la matiÃ¨re sont requises.", "danger")
        return redirect(url_for("admin_dashboard"))
    try:
        sort_order = int(sort_order)
    except ValueError:
        sort_order = 0
    ensure_courses_table()
    try:
        with db() as conn:
            cur = conn.cursor()
            cur.execute("""
                INSERT INTO course_subjects (course_code, subject, sort_order)
                VALUES (%s,%s,%s)
            """, (course_code, subject, sort_order))
            conn.commit(); cur.close()
        flash("MatiÃ¨re ajoutÃ©e.", "success")
    except IntegrityError:
        flash("Cette matiÃ¨re existe dÃ©jÃ  pour cette formation.", "warning")
    return redirect(url_for("admin_dashboard"))

@app.route("/admin/courses/subjects/delete/<int:sid>")
@login_required("admin")
def admin_delete_course_subject(sid):
    ensure_courses_table()
    with db() as conn:
        cur = conn.cursor()
        cur.execute("DELETE FROM course_subjects WHERE id=%s", (sid,))
        conn.commit(); cur.close()
    flash("MatiÃ¨re supprimÃ©e.", "warning")
    return redirect(url_for("admin_dashboard"))

@app.route("/admin/users/<int:uid>/assign-teacher", methods=["POST"])
@login_required("admin")
def admin_assign_teacher(uid):
    level = request.form.get("level","").strip()
    subject = request.form.get("subject","").strip()
    if not level or not subject:
        flash("La formation et la matiÃ¨re sont requises.", "danger")
        return redirect(url_for("admin_dashboard"))
    allowed_subjects = {row["subject"] for row in fetch_course_subjects(level)}
    if subject not in allowed_subjects:
        return redirect(url_for("admin_dashboard"))
    with db() as conn:
        cur = conn.cursor()
        cur.execute("UPDATE users SET level=%s, subject=%s WHERE id=%s AND role='teacher'",
                    (level, subject, uid))
        conn.commit(); cur.close()
    flash("Compte enseignant mis Ã  jour.", "success")
    return redirect(url_for("admin_dashboard"))

@app.route("/admin/courses/delete/<int:cid>")
@login_required("admin")
def admin_delete_course(cid):
    ensure_courses_table()
    with db() as conn:
        cur = conn.cursor()
        cur.execute("DELETE FROM courses WHERE id=%s", (cid,))
        conn.commit(); cur.close()
    flash("Formation supprimÃ©e.", "warning")
    return redirect(url_for("admin_dashboard"))

@app.route("/admin/create-teacher", methods=["POST"])
@login_required("admin")
def admin_create_teacher():
    t_user  = request.form.get("t_username","").strip()
    t_phone = request.form.get("t_phone","").strip()
    t_pass  = request.form.get("t_password","")
    t_level = request.form.get("t_level") or None
    t_subject = request.form.get("t_subject","").strip() or None
    if not t_user or not t_phone or not t_pass or not t_level or not t_subject:
        flash("Nom dâ€™utilisateur, numÃ©ro et mot de passe sont requis.", "danger")
        return redirect(url_for("admin_dashboard"))
    try:
        with db() as conn:
            cur = conn.cursor()
            cur.execute("""INSERT INTO users (username, phone, password, role, level, subject, status, phone_verified)
                           VALUES (%s,%s,%s,'teacher',%s,%s,'active',TRUE)""",
                        (t_user, t_phone, hash_password(t_pass), t_level, t_subject))
            conn.commit(); cur.close()
        flash("Compte enseignant crÃ©Ã©.", "success")
    except IntegrityError as e:
        msg = "Nom dâ€™utilisateur dÃ©jÃ  utilisÃ©."
        if "phone" in str(e): msg = "NumÃ©ro de tÃ©lÃ©phone dÃ©jÃ  utilisÃ©."
        flash(msg, "danger")
    return redirect(url_for("admin_dashboard"))

# ===== Tableau de bord Enseignant =====
@app.route("/teacher", methods=["GET","POST"])
@login_required("teacher")
def teacher_dashboard():
    courses = fetch_courses(active_only=True)
    assigned_level = session.get("level")
    assigned_subject = session.get("subject")
    if request.method == "POST":
        subject = assigned_subject
        chapter = request.form.get("chapter_title","").strip()
        level   = assigned_level
        vfile   = request.files.get("video")
        pfile   = request.files.get("pdf")
        vurl    = request.form.get("video_url","").strip() or None  # NEW: video url

        if not subject or not chapter or not level:
            flash("Champs obligatoires manquants.", "danger"); return redirect(url_for("teacher_dashboard"))

        vname = None; pname = None
        if vfile and vfile.filename and allowed(vfile.filename, VIDEO_EXT):
            base = secure_filename(vfile.filename)
            vname = f"{session['user_id']}_{int(time.time())}_{base}"
            vfile.save(os.path.join(VID_DIR, vname))
        if pfile and pfile.filename and allowed(pfile.filename, PDF_EXT):
            base = secure_filename(pfile.filename)
            pname = f"{session['user_id']}_{int(time.time())}_{base}"
            pfile.save(os.path.join(PDF_DIR, pname))

        with db() as conn:
            cur = conn.cursor()
            # NEW: insert video_url
            cur.execute("""INSERT INTO lessons (subject,chapter_title,level,video_file,pdf_file,video_url,uploaded_by)
                           VALUES (%s,%s,%s,%s,%s,%s,%s)""",
                        (subject, chapter, level, vname, pname, vurl, session["user_id"]))
            conn.commit(); cur.close()
        flash("LeÃ§on ajoutÃ©e.", "success")
        return redirect(url_for("teacher_dashboard"))

    with db() as conn:
        cur = dict_cursor(conn)
        cur.execute("""SELECT * FROM lessons
                       WHERE uploaded_by=%s AND level=%s AND subject=%s
                       ORDER BY uploaded_at DESC""",
                    (session["user_id"], assigned_level, assigned_subject))
        my_lessons = cur.fetchall(); cur.close()
    return render_template("teacher.html", lessons=my_lessons, courses=courses,
                           assigned_level=assigned_level, assigned_subject=assigned_subject)

# ===== Tableau de bord Ã‰tudiant =====
@app.route("/student")
@login_required("student")
def student_dashboard():
    level = session.get("level")
    subject = request.args.get("subject")  # NEW: optional filter
    subjects = fetch_course_subjects(level) if level else []
    allowed_subjects = {row["subject"] for row in subjects}
    if subject and subject not in allowed_subjects:
        subject = None
    with db() as conn:
        cur = dict_cursor(conn)
        cur.execute("SELECT phone FROM users WHERE id=%s", (session["user_id"],))
        student = cur.fetchone()
        if subject:
            cur.execute("""SELECT * FROM lessons
                           WHERE level=%s AND subject=%s
                           ORDER BY uploaded_at DESC""",
                        (level, subject))
        else:
            cur.execute("""SELECT * FROM lessons
                           WHERE level=%s
                           ORDER BY CASE subject
                                      WHEN 'Math' THEN 1
                                      WHEN 'Physique' THEN 2
                                      WHEN 'Chimie' THEN 3
                                      WHEN 'Science naturelle' THEN 4
                                      ELSE 5
                                    END,
                                    uploaded_at DESC""",
                        (level,))
        lessons = cur.fetchall(); cur.close()
    return render_template("student.html", lessons=lessons, level=level,
                           subjects=subjects, student=student)

if __name__ == "__main__":
    try:
        # Pick the outbound LAN address instead of a virtual adapter like 192.168.56.1.
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
            s.connect(("8.8.8.8", 80))
            local_ip = s.getsockname()[0]
    except Exception:
        try:
            local_ip = socket.gethostbyname(socket.gethostname())
        except Exception:
            local_ip = "127.0.0.1"
    print("Uploads:", UP)
    print(f"Open from this PC: http://127.0.0.1:5000")
    print(f"Open from phone on same Wi-Fi: http://{local_ip}:5000")
    app.run(host='0.0.0.0', port=5000, debug=False, use_reloader=False)
