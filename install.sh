#!/bin/bash

echo "----------------------------"
echo " TikTok Clone Setup Script "
echo "----------------------------"
echo
echo "Before starting:"
echo "- Make sure you have a domain and its A record points to this server."
echo "- Example: videos.yourdomain.com --> [This VPS IP]"
echo

# Ask for hostname (domain) and email
read -p "Enter your domain name (without https://): " MYDOMAIN
read -p "Enter your email for SSL (Let’s Encrypt): " MYEMAIL

echo
echo "Using domain: $MYDOMAIN"
echo "Using email: $MYEMAIL"
echo

# --- 1. Install dependencies ---
sudo apt update
sudo apt install -y apache2 php php-mysql mysql-server ffmpeg unzip certbot python3-certbot-apache

# --- 2. Secure MySQL and create database ---
DBPASS="tiktokclonepass"
DBNAME="tiktokclone"
DBUSER="tiktokadmin"

sudo mysql -e "CREATE DATABASE IF NOT EXISTS $DBNAME;"
sudo mysql -e "CREATE USER IF NOT EXISTS '$DBUSER'@'localhost' IDENTIFIED BY '$DBPASS';"
sudo mysql -e "GRANT ALL PRIVILEGES ON $DBNAME.* TO '$DBUSER'@'localhost';"
sudo mysql -e "FLUSH PRIVILEGES;"

# --- 3. Set up directories ---
sudo mkdir -p /var/www/html/videos
sudo mkdir -p /var/www/html/api
sudo mkdir -p /var/www/html/admin
sudo chown -R www-data:www-data /var/www/html/videos

# --- 4. Create database table ---
sudo mysql -u $DBUSER -p$DBPASS $DBNAME <<EOF
CREATE TABLE IF NOT EXISTS videos (
  id INT AUTO_INCREMENT PRIMARY KEY,
  filename VARCHAR(255) NOT NULL,
  title VARCHAR(255),
  duration INT,
  uploaded_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);
EOF

# --- 5. Deploy API ---

cat <<'EOP' | sudo tee /var/www/html/api/videos.php > /dev/null
<?php
header("Access-Control-Allow-Origin: *");
header('Content-Type: application/json');
$mysqli = new mysqli("localhost", "tiktokadmin", "tiktokclonepass", "tiktokclone");
if ($mysqli->connect_errno) {
    echo json_encode(["error" => "DB error"]); exit;
}
if ($_SERVER['REQUEST_METHOD'] == 'GET') {
    $res = $mysqli->query("SELECT id, filename, title, duration, uploaded_at FROM videos ORDER BY id DESC");
    $out = [];
    while($row = $res->fetch_assoc()) {
        $row['url'] = '/videos/' . $row['filename'];
        $out[] = $row;
    }
    echo json_encode($out); exit;
}
if ($_SERVER['REQUEST_METHOD'] == 'DELETE') {
    parse_str(file_get_contents("php://input"), $_DEL);
    $id = intval($_DEL['id']);
    $res = $mysqli->query("SELECT filename FROM videos WHERE id=$id");
    if ($row = $res->fetch_assoc()) {
        unlink("../videos/" . $row['filename']);
    }
    $mysqli->query("DELETE FROM videos WHERE id=$id");
    echo json_encode(["success" => true]); exit;
}
?>
EOP

cat <<'EOP' | sudo tee /var/www/html/api/upload.php > /dev/null
<?php
$mysqli = new mysqli("localhost", "tiktokadmin", "tiktokclonepass", "tiktokclone");
if ($_SERVER['REQUEST_METHOD'] == 'POST' && isset($_FILES['video'])) {
    $title = $mysqli->real_escape_string($_POST['title'] ?? '');
    $tmp = $_FILES['video']['tmp_name'];
    $basename = uniqid() . '.mp4';
    $target = "../videos/" . $basename;
    // FFmpeg compress
    $cmd = "ffmpeg -i $tmp -vcodec libx264 -crf 28 -preset veryfast -acodec aac -b:a 64k -vf 'scale=480:-2' $target -y";
    exec($cmd);
    // Duration
    $getDuration = "ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 $target";
    $duration = intval(exec($getDuration));
    $mysqli->query("INSERT INTO videos (filename, title, duration) VALUES ('$basename', '$title', $duration)");
    header("Location: /admin/index.php?ok=1");
    exit;
}
?>
EOP

cat <<'EOP' | sudo tee /var/www/html/api/edit.php > /dev/null
<?php
$mysqli = new mysqli("localhost", "tiktokadmin", "tiktokclonepass", "tiktokclone");
if ($_SERVER['REQUEST_METHOD'] == 'POST') {
    $id = intval($_POST['id']);
    $title = $mysqli->real_escape_string($_POST['title'] ?? '');
    $mysqli->query("UPDATE videos SET title='$title' WHERE id=$id");
    header("Location: /admin/index.php?ok=1");
    exit;
}
?>
EOP

cat <<'EOP' | sudo tee /var/www/html/api/delete.php > /dev/null
<?php
$mysqli = new mysqli("localhost", "tiktokadmin", "tiktokclonepass", "tiktokclone");
if ($_SERVER['REQUEST_METHOD'] == 'POST') {
    $id = intval($_POST['id']);
    $res = $mysqli->query("SELECT filename FROM videos WHERE id=$id");
    if ($row = $res->fetch_assoc()) {
        unlink("../videos/" . $row['filename']);
    }
    $mysqli->query("DELETE FROM videos WHERE id=$id");
    header("Location: /admin/index.php?ok=1");
    exit;
}
?>
EOP

# --- 6. Modern Responsive Admin Panel ---

cat <<'EOP' | sudo tee /var/www/html/admin/index.php > /dev/null
<?php
$mysqli = new mysqli("localhost", "tiktokadmin", "tiktokclonepass", "tiktokclone");
$videos = $mysqli->query("SELECT * FROM videos ORDER BY id DESC");
?>
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <title>Admin Panel — TikTok Clone</title>
  <meta name="viewport" content="width=device-width,initial-scale=1">
  <link href="https://fonts.googleapis.com/css2?family=Inter:wght@400;600&display=swap" rel="stylesheet">
  <style>
    body {
      font-family: 'Inter', Arial, sans-serif;
      background: #16181F;
      color: #fff;
      margin: 0;
      padding: 0;
      min-height: 100vh;
    }
    .admin-wrap {
      max-width: 900px;
      margin: 38px auto;
      padding: 30px 18px 30px 18px;
      background: #23252F;
      border-radius: 18px;
      box-shadow: 0 6px 36px #0002;
    }
    h1, h2 {
      margin-top: 0;
      font-weight: 600;
      letter-spacing: -1px;
    }
    .upload-form {
      display: flex;
      flex-wrap: wrap;
      gap: 10px;
      margin-bottom: 30px;
      background: #191A23;
      padding: 18px 12px;
      border-radius: 10px;
      box-shadow: 0 1px 7px #0002;
      align-items: center;
    }
    .upload-form input[type="text"], .upload-form input[type="file"] {
      padding: 9px 10px;
      border-radius: 6px;
      border: none;
      font-size: 1em;
      outline: none;
      background: #23252F;
      color: #FFF;
      margin-right: 10px;
    }
    .upload-form button {
      background: #FFD700;
      color: #23252F;
      padding: 9px 18px;
      border: none;
      border-radius: 6px;
      font-weight: 600;
      cursor: pointer;
      transition: background 0.2s;
      font-size: 1em;
      box-shadow: 0 1px 6px #FFD70040;
    }
    .upload-form button:hover { background: #FFB300; color:#FFF; }
    table {
      width: 100%;
      border-collapse: collapse;
      background: #181A20;
      border-radius: 12px;
      overflow: hidden;
      margin-top: 12px;
      box-shadow: 0 1px 10px #0003;
    }
    th, td {
      padding: 10px 7px;
      text-align: center;
      border-bottom: 1px solid #22242C;
    }
    th {
      background: #22242C;
      color: #FFD700;
      font-weight: 600;
      font-size: 1em;
    }
    td form {
      display: inline;
    }
    td input[type="text"] {
      padding: 7px 7px;
      font-size: 1em;
      border-radius: 5px;
      border: none;
      background: #23252F;
      color: #FFD700;
      width: 90px;
      margin-right: 4px;
    }
    td button {
      background: #22242C;
      color: #FFD700;
      border: none;
      padding: 7px 12px;
      border-radius: 6px;
      cursor: pointer;
      font-weight: 600;
      transition: background 0.2s;
      margin: 0 2px;
      font-size: 1em;
    }
    td button:hover { background: #FFD700; color: #22242C;}
    .okmsg {
      color: #12ff7e;
      background: #232E1F;
      display: inline-block;
      padding: 7px 22px;
      border-radius: 7px;
      font-weight: 600;
      margin-bottom: 20px;
      letter-spacing: .5px;
      box-shadow: 0 2px 10px #0013;
    }
    @media (max-width:600px) {
      .admin-wrap { padding: 12px 2px; margin:10px 1vw;}
      .upload-form { flex-direction:column; align-items:stretch;}
      table, th, td { font-size: 0.96em;}
      td input[type="text"] { width:80%; }
    }
  </style>
</head>
<body>
  <div class="admin-wrap">
    <h1>📹 TikTok Clone — Admin Panel</h1>
    <form class="upload-form" action="/api/upload.php" method="post" enctype="multipart/form-data">
      <input type="text" name="title" placeholder="Video title" required>
      <input type="file" name="video" accept="video/*" required>
      <button type="submit">Upload Video</button>
    </form>
    <?php if(isset($_GET['ok'])): ?>
      <div class="okmsg">✅ Operation successful.</div>
    <?php endif; ?>

    <h2 style="margin-top:22px;">All Videos</h2>
    <div style="overflow-x:auto;">
    <table>
      <tr>
        <th>ID</th>
        <th>Title</th>
        <th>File</th>
        <th>Duration</th>
        <th>Actions</th>
      </tr>
      <?php while($v = $videos->fetch_assoc()): ?>
      <tr>
        <td><?= $v['id'] ?></td>
        <td>
          <form action="/api/edit.php" method="post" style="display:inline">
            <input type="hidden" name="id" value="<?= $v['id'] ?>">
            <input type="text" name="title" value="<?= htmlspecialchars($v['title']) ?>">
            <button type="submit" title="Save title">💾</button>
          </form>
        </td>
        <td>
          <a href="/videos/<?= $v['filename'] ?>" target="_blank" style="color:#FFD700;font-weight:600;text-decoration:underline;">Play</a>
        </td>
        <td><?= $v['duration'] ?>s</td>
        <td>
          <form action="/api/delete.php" method="post" onsubmit="return confirm('Delete this video?');" style="display:inline;">
            <input type="hidden" name="id" value="<?= $v['id'] ?>">
            <button type="submit" title="Delete">🗑️</button>
          </form>
        </td>
      </tr>
      <?php endwhile; ?>
    </table>
    </div>
  </div>
</body>
</html>
EOP

# --- 7. Modern Responsive Web Video Preview ---

cat <<'EOP' | sudo tee /var/www/html/index.php > /dev/null
<?php
$mysqli = new mysqli("localhost", "tiktokadmin", "tiktokclonepass", "tiktokclone");
$v = $mysqli->query("SELECT * FROM videos ORDER BY id DESC LIMIT 1")->fetch_assoc();
?>
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <title>TikTok Clone Video</title>
  <meta name="viewport" content="width=device-width,initial-scale=1">
  <link href="https://fonts.googleapis.com/css2?family=Inter:wght@400;600&display=swap" rel="stylesheet">
  <style>
    body {
      font-family: 'Inter', Arial, sans-serif;
      background: #181A20;
      color: #FFF;
      margin: 0; padding: 0;
      display: flex; flex-direction: column; align-items: center; min-height: 100vh;
    }
    .container {
      margin-top: 48px;
      background: #23252F;
      border-radius: 18px;
      padding: 30px 20px;
      box-shadow: 0 6px 32px #0002;
      max-width: 420px;
      width: 96vw;
      display: flex; flex-direction: column; align-items: center;
    }
    video {
      width: 100%;
      border-radius: 18px;
      background: #111;
      box-shadow: 0 2px 12px #0007;
      margin-bottom: 18px;
    }
    .title {
      font-size: 1.2em;
      font-weight: 600;
      margin: 12px 0 6px 0;
      color: #FFD700;
      text-shadow: 0 2px 4px #0008;
    }
    .duration {
      font-size: 0.93em;
      color: #BBB;
      margin-bottom: 8px;
    }
    .install {
      margin-top: 22px;
      background: #FFD700;
      color: #181A20;
      padding: 13px 28px;
      border-radius: 8px;
      font-size: 1.05em;
      font-weight: 600;
      box-shadow: 0 1px 8px #FFD70030;
      text-decoration: none;
      display: inline-block;
      transition: background 0.2s;
    }
    .install:hover { background: #FFB300; color: #FFF; }
    @media (max-width:600px) {
      .container { margin-top: 24px; padding:18px 5px; }
      video { max-height:55vw; }
    }
  </style>
</head>
<body>
  <div class="container">
    <h2 style="margin:0 0 16px 0; font-weight:600; font-size:1.5em; letter-spacing:-1px;">TikTok Clone Preview</h2>
    <?php if($v): ?>
      <video src="/videos/<?= $v['filename'] ?>" controls autoplay loop playsinline></video>
      <div class="title"><?= htmlspecialchars($v['title']) ?></div>
      <div class="duration"><?= $v['duration'] ?> sec</div>
      <a class="install" href="#" onclick="alert('APK coming soon!');return false;">⬇️ Install Our Android App for More Videos!</a>
    <?php else: ?>
      <div style="color:#CCC;padding:36px 0;font-size:1.15em;">No video uploaded yet.</div>
    <?php endif; ?>
  </div>
</body>
</html>
EOP

# --- 8. Set Permissions ---
sudo chown -R www-data:www-data /var/www/html/videos

# --- 9. Configure Apache for your domain and SSL ---

# Backup config just in case
sudo cp /etc/apache2/sites-available/000-default.conf /etc/apache2/sites-available/000-default.conf.bak

# Set ServerName and DocumentRoot for your domain
sudo bash -c "cat > /etc/apache2/sites-available/000-default.conf" <<EOF
<VirtualHost *:80>
    ServerName $MYDOMAIN
    DocumentRoot /var/www/html
    <Directory /var/www/html>
        AllowOverride All
    </Directory>
    ErrorLog \${APACHE_LOG_DIR}/error.log
    CustomLog \${APACHE_LOG_DIR}/access.log combined
</VirtualHost>
EOF

sudo systemctl reload apache2

# --- 10. Enable SSL with Certbot ---

sudo certbot --apache -d $MYDOMAIN --non-interactive --agree-tos -m $MYEMAIL

# --- 11. Force HTTP->HTTPS redirect ---
sudo sed -i "/<\/VirtualHost>/i\
RewriteEngine On\nRewriteCond %{HTTPS} off\nRewriteRule (.*) https://%{HTTP_HOST}%{REQUEST_URI} [L,R=301]" /etc/apache2/sites-available/000-default.conf

sudo systemctl reload apache2

echo "=============================================="
echo " TikTok-Clone setup completed with SSL! "
echo " Visit: https://$MYDOMAIN/admin"
echo "=============================================="
