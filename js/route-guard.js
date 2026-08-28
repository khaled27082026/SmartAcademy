// ============================================================
// ============================================================
//
//   <script>
//       window.SA_REQUIRED_ROLE = { sessionKey: 'sa_current_student', loginUrl: 'student-login/' };
//   </script>
//   <script src="js/route-guard.js"></script>
//
// (sa_current_student / sa_current_teacher / sa_current_admin /
(function () {
    var role = window.SA_REQUIRED_ROLE;
    if (!role || !role.sessionKey || !role.loginUrl) return;

    function isValidSession(key) {
        try {
            var raw = JSON.parse(localStorage.getItem(key));
            return !!(raw && raw.data && raw.expiresAt && Date.now() <= raw.expiresAt);
        } catch (e) {
            return false;
        }
    }

    if (!isValidSession(role.sessionKey)) {
        window.location.replace(role.loginUrl);
    }
})();
