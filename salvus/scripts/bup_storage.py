#!/usr/bin/env python

"""

BUP/ZFS-based project storage system

The basic idea:

   - a bup repo with snapshot history of a project is stored on k machines in each data center, with a way to sync repos
   - live files are also stored on those same k machines in a directory as part of one big dedup'd and compressed zpool, which is snapshotted regularly
   - all internode/interdata centerreplication is done via rsync
   - Loss of files is very hard, because the files and their history is contained in:
            (1) the bup repos  (backed up offsite)
            (2) the snapshots of the big single shared zfs filesystem (not backed up)
     Note that project history may move when new nodes are added, due to consistent hashing.  But the zfs snapshots still exist.


INSTALL:

In visudo:

    salvus ALL=(ALL) NOPASSWD: /usr/local/bin/bup_storage.py *

Install script:

     cp /home/salvus/salvus/salvus/scripts/bup_storage.py /usr/local/bin/
     chown root:salvus /usr/local/bin/bup_storage.py
     chmod ug+rx /usr/local/bin/bup_storage.py
     chmod og-w /usr/local/bin/bup_storage.py
     chmod o-x /usr/local/bin/bup_storage.py

"""
# If UNSAFE_MODE=False, we only provide a restricted subset of options.  When this
# script will be run via sudo, it is useful to minimize what it is able to do, e.g.,
# there is no reason it should have easy command-line options to overwrite any file
# on the system with arbitrary content.
UNSAFE_MODE=False

import argparse, hashlib, math, os, random, shutil, socket, string, sys, time, uuid, json, signal, math, pwd
from subprocess import Popen, PIPE
from uuid import UUID, uuid4

USERNAME =  pwd.getpwuid(os.getuid())[0]

# If using ZFS:
ZPOOL = 'bup'  # must have ZPOOL/bups and ZPOOL/projects filesystems

# The path where bup repos are stored
BUP_PATH       = '/bup/bups'

# The path where project working files appear
PROJECTS_PATH  = '/projects'
PROJECTS_PATH  = '/bup/projects'

# Where the server_id is stored
SERVER_ID_FILE = '/bup/conf/bup_server_id'

# Where the file containing info about all servers is stored
SERVERS_FILE   = '/bup/conf/bup_servers'

REPLICATION_FACTOR = 1

# Default account settings

DEFAULT_SETTINGS = {
    'disk'       : 4000,     # disk in megabytes
    'scratch'    : 15000,    # disk quota on /scratch
    'inode'      : 200000,   # not used with ZFS
    'memory'     : 8,        # memory in gigabytes
    'cpu_shares' : 256,
    'cores'      : 2,
    'login_shell': '/bin/bash',
    'mintime'    : 60*60*3,  # default = 3 hours idle (no save) time before kill
}

FILESYSTEM = 'zfs'   # 'zfs' or 'ext4'

if FILESYSTEM == 'ext4':
    if not os.path.exists(BUP_PATH):
        cmd("/bin/mkdir -p %s; chmod og-rwx %s"%(BUP_PATH, BUP_PATH))

    if not os.path.exists(PROJECTS_PATH):
        cmd("/bin/mkdir -p %s; chmod og+rx %s"%(PROJECTS_PATH, PROJECTS_PATH))


# Make sure to copy: 'cp -rv ~/salvus/salvus/scripts/skel/.sagemathcloud/data /home/salvus/salvus/salvus/local_hub_template/"
SAGEMATHCLOUD_TEMPLATE = "/home/salvus/salvus/salvus/local_hub_template/"

BASHRC_TEMPLATE        = "/home/salvus/salvus/salvus/scripts/skel/.bashrc"
BASH_PROFILE_TEMPLATE  = "/home/salvus/salvus/salvus/scripts/skel/.bash_profile"

#SSH_ACCESS_PUBLIC_KEY  = "/home/salvus/salvus/salvus/scripts/skel/.ssh/authorized_keys2"

def log(m):
    sys.stderr.write(str(m)+'\n')
    sys.stderr.flush()

def print_json(s):
    print json.dumps(s, separators=(',',':'))

def uid(project_id):
    # We take the sha-512 of the uuid just to make it harder to force a collision.  Thus even if a
    # user could somehow generate an account id of their choosing, this wouldn't help them get the
    # same uid as another user.
    # 2^31-1=max uid which works with FUSE and node (and Linux, which goes up to 2^32-2).
    n = int(hashlib.sha512(project_id).hexdigest()[:8], 16)  # up to 2^32
    n /= 2  # up to 2^31
    return n if n>65537 else n+65537   # 65534 used by linux for user sync, etc.

def now():
    return time.strftime('%Y-%m-%dT%H:%M:%S')

def ensure_file_exists(src, target):
    if not os.path.exists(target):
        shutil.copyfile(src, target)
        s = os.stat(os.path.split(target)[0])
        if USERNAME == "root":
            os.chown(target, s.st_uid, s.st_gid)

def check_uuid(uuid):
    if UUID(uuid).version != 4:
        raise RuntimeError("invalid uuid")


def cmd(s, ignore_errors=False, verbose=2, timeout=None, stdout=True, stderr=True):
    if isinstance(s, list):
        s = [str(x) for x in s]
    if verbose >= 1:
        if isinstance(s, list):
            t = [x if len(x.split()) <=1  else "'%s'"%x for x in s]
            log(' '.join(t))
        else:
            log(s)
    t = time.time()

    mesg = "ERROR"
    if timeout:
        mesg = "TIMEOUT: running '%s' took more than %s seconds, so killed"%(s, timeout)
        def handle(*a):

            if ignore_errors:
                return mesg
            else:
                raise KeyboardInterrupt(mesg)
        signal.signal(signal.SIGALRM, handle)
        signal.alarm(timeout)
    try:
        out = Popen(s, stdin=PIPE, stdout=PIPE, stderr=PIPE, shell=not isinstance(s, list))
        x = out.stdout.read() + out.stderr.read()
        e = out.wait()  # this must be *after* the out.stdout.read(), etc. above or will hang when output large!
        if e:
            if ignore_errors:
                return (x + "ERROR").strip()
            else:
                raise RuntimeError(x)
        if verbose>=2:
            log("(%s seconds): %s"%(time.time()-t, x))
        elif verbose >= 1:
            log("(%s seconds)"%(time.time()-t))
        return x.strip()
    except IOError:
        return mesg
    finally:
        if timeout:
            signal.signal(signal.SIGALRM, signal.SIG_IGN)  # cancel the alarm

class Project(object):
    def __init__(self, project_id):
        try:
            assert uuid.UUID(project_id).get_version() == 4
        except (AssertionError, ValueError):
            raise RuntimeError("invalid project uuid='%s'"%project_id)
        self.project_id            = project_id
        self.uid                   = uid(project_id)
        self.gid                   = self.uid
        self.username              = self.project_id.replace('-','')
        self.groupname             = self.username
        self.bup_path              = os.path.join(BUP_PATH, project_id)
        self.conf_path             = os.path.join(self.bup_path, "conf")
        self.settings_path         = os.path.join(self.conf_path, "settings.json")
        self.replicas_path         = os.path.join(self.conf_path, "replicas.json")
        self.project_mnt           = os.path.join(PROJECTS_PATH, project_id)
        self.snap_mnt              = os.path.join(self.project_mnt, '.snapshots')
        self.touch_file            = os.path.join(self.bup_path, "conf", "touch")
        self.save_log              = os.path.join(self.bup_path, "conf", "save_log.json")
        self.HEAD                  = "%s/HEAD"%self.bup_path
        self.branch = open(self.HEAD).read().split('/')[-1].strip() if os.path.exists(self.HEAD) else 'master'

    def cmd(self, *args, **kwds):
        os.environ['BUP_DIR'] = self.bup_path
        return cmd(*args, **kwds)

    def __repr__(self):
        return "Project(%s)"%project_id

    def _log(self, funcname, **kwds):
        def f(mesg=''):
            log("%s(project_id=%s,%s): %s"%(funcname, self.project_id, kwds, mesg))
        f()
        return f

    def create_user(self):
        self.create_home()
        login_shell = self.get_settings()['login_shell']
        if self.gid == self.uid:
            self.cmd(['/usr/sbin/groupadd', '-g', self.gid, '-o', self.username], ignore_errors=True)
        self.cmd(['/usr/sbin/useradd', '-u', self.uid, '-g', self.gid, '-o', self.username,
                  '-d', self.project_mnt, '-s', login_shell], ignore_errors=True)

    def delete_user(self):
        self.cmd(['/usr/sbin/userdel', self.username], ignore_errors=True)
        if self.gid == self.uid:
            self.cmd(['/usr/sbin/groupdel', self.username], ignore_errors=True)

    def start_daemons(self):
        self.cmd(['su', '-', self.username, '-c', 'cd .sagemathcloud; . sagemathcloud-env; ./start_smc'], timeout=30)

    def start(self):
        self.init()
        self.create_home()
        self.delete_user()
        self.create_user()
        self.settings()
        self.ensure_conf_files()
        self.touch()
        self.update_daemon_code()
        self.start_daemons()
        self.umount_snapshots()
        # TODO: remove this chown once (1) uid defn stabilizes
        # self.cmd(["chown", "-R", "%s:%s"%(self.username, self.groupname), self.project_mnt])
        self.mount_snapshots()

    def get_zfs_status(self):
        q = {}
        try:
            for x in ['userquota', 'userused']:
                for y in ['projects', 'scratch']:
                    q['%s-%s'%(x,y)] = cmd(['zfs', 'get', '-H', '%s@%s'%(x,self.uid), '%s/%s'%(ZPOOL,y)]).split()[2]
            return q
        except RuntimeError:
            return None

    def status(self):
        log = self._log("status")
        s = {'username':self.username, 'uid':self.uid, 'gid':self.gid, 'settings':self.get_settings()}
        try:
            s['newest_snapshot'] = self.newest_snapshot()
            s['bup'] = 'working'
        except RuntimeError, mesg:
            mesg = str(mesg)
            if 'bup init' in mesg:
                s['bup'] = 'uninitialized'  # it's just not initialized, which is no problem
            else:
                s['bup'] = mesg
        s['load'] = [float(a.strip(',')) for a in os.popen('uptime').read().split()[-3:]]
        if FILESYSTEM == 'zfs':
            s['zfs'] = self.get_zfs_status()
        if self.username not in open('/etc/passwd').read():  # TODO: can be done better
            s['running'] = False
            return s
        try:
            t = self.cmd(['su', '-', self.username, '-c', 'cd .sagemathcloud; . sagemathcloud-env; ./status'], timeout=30)
            t = json.loads(t)
            s.update(t)
            s['running'] = bool(t.get('local_hub.pid',False))
            return s
        except Exception, msg:
            log("Error getting status -- %s"%msg)
            s['running'] = False
            return s

    def create_home(self):
        self._log('create_home')
        if not os.path.exists(self.project_mnt):
            self.makedirs(self.project_mnt)
        if USERNAME == "root":
            os.chown(self.project_mnt, self.uid, self.gid)

    def init(self):
        """
        Create user home directory and  bup repo.
        """
        log = self._log("create")
        if not os.path.exists(os.path.join(self.bup_path,'objects')):
            self.cmd(['/usr/bin/bup', 'init'])
        self.create_home()
        self.makedirs(self.conf_path)

    def set_branch(self, branch=''):
        if branch and branch != self.branch:
            self.branch = branch
            open(self.HEAD,'w').write("ref: refs/heads/%s"%branch)

    def checkout(self, snapshot='latest', branch=None):
        self.set_branch(branch)
        if not os.path.exists(self.project_mnt):
            self.makedirs(self.project_mnt)
            self.cmd(['/usr/bin/bup', 'restore', '%s/%s/'%(self.branch, snapshot), '--outdir', self.project_mnt])
            self.chown(self.project_mnt)
        else:
            src = os.path.join(self.snap_mnt, self.branch, snapshot)+'/'
            self.cmd(['rsync', '-axH', '--delete', self.exclude(src), src, self.project_mnt+'/'])

    def umount_snapshots(self):
        self.cmd(['fusermount', '-uz', self.snap_mnt], ignore_errors=True)

    def mount_snapshots(self):
        log = self._log('mount_snapshots')
        self.umount_snapshots()
        if os.path.exists(self.snap_mnt):
            os.rmdir(self.snap_mnt)
        try:
            self.makedirs(self.snap_mnt)
            self.cmd(['bup', 'fuse', '-o', '--uid', self.uid, '--gid', self.gid, self.snap_mnt])
        except Exception, msg:
            # if there is no space to make the snapshot directory, user gets no snapshots.
            if 'Disk quota exceeded' in msg:
                log("nonfatal error -- %s"%msg)
            else:
                raise


    def touch(self):
        open(self.touch_file,'w')

    def last_touch_time(self):
        if os.path.exists(self.touch_file):
            return os.path.getmtime(self.touch_file)
        else:
            return time.time() # now -- since could be just creating project

    def stop(self, grace_s=0.5, only_if_idle=False):
        log = self._log('stop')
        if only_if_idle:
            log("checking if project is idle regarding saves")
            mintime = self.get_settings()['mintime']
            if mintime <= 0:
                log("nope -- it has infinite time")
            else:
                last = self.last_touch_time()
                time_since_last = time.time() - last
                log(" time_since_last = %s and mintime = %s"%( time_since_last , mintime))
                if  time_since_last  < mintime:
                    log("hasn't been long enough -- not stopping")
                    return

        log("killing all processes by user with id %s"%self.uid)
        MAX_TRIES=10
        # we use both kill and pkill -- pkill seems better in theory, but I've definitely seen it get ignored.
        for i in range(MAX_TRIES):
            self.cmd(['/usr/bin/killall', '-u', self.username], ignore_errors=True)
            self.cmd(['/usr/bin/pkill', '-u', self.uid], ignore_errors=True)
            time.sleep(grace_s)
            self.cmd(['/usr/bin/killall', '-9', '-u', self.username], ignore_errors=True)
            self.cmd(['/usr/bin/pkill', '-9', '-u', self.uid], ignore_errors=True)
            n = self.num_procs()
            log("kill attempt left %s procs"%n)
            if n == 0:
                break
        self.delete_user()  # so crontabs, remote logins, etc., won't happen
        self.unset_quota()
        self.umount_snapshots()

    def restart(self):
        self.stop()
        self.start()

    def pids(self):
        return [int(x) for x in cmd(['pgrep', '-u', self.uid], ignore_errors=True).replace('ERROR','').split()]

    def num_procs(self):
        return len(self.pids())

    def archive(self):
        """
        Remove the user's files, leaving only the bup repo.

        ** DANGEROUS. **

        This would be used when it is highly unlikely the project will ever be used again, e.g.,
        maybe when one deletes a project, and we want to keep it around for a while for archival
        purposes, just in case.
        """
        log = self._log("archive")
        self.stop()
        self.umount_snapshots()
        log("removing users files")
        shutil.rmtree(self.project_mnt)
        self.delete_user()

    def destroy(self):
        """
        *VERY DANGEROUS.*  Delete all traces of this project from this machine.
        """
        self.archive()
        shutil.rmtree(self.bup_path)

    def exclude(self, prefix):
        excludes = ['*.sage-backup', '.sage/cache', '.fontconfig', '.sage/temp', '.zfs', '.npm', '.sagemathcloud', '.node-gyp', '.cache', '.forever', '.snapshots', 'core']
        return ['--exclude=%s'%(prefix+x) for x in excludes]

    def save(self, path=None, timestamp=None, branch=None, sync=True, mnt=True, targets=""):
        """
        Save a snapshot.

        If sync is true, also syncs data out and returns info about how successful that was.
        """
        log = self._log("save")
        self.touch()
        self.set_branch(branch)
        if path is None:
            path = self.project_mnt

        # We ignore_errors below because unfortunately bup will return a nonzero exit code ("WARNING")
        # when it hits a fuse filesystem.   TODO: somehow be more careful that each
        self.cmd(["/usr/bin/bup", "index", "-x"] + self.exclude(path+'/') + [path], ignore_errors=True)

        what_changed = self.cmd(["/usr/bin/bup", "index", '-m', path],verbose=0).splitlines()
        files_saved = max(0, len(what_changed) - 1)      # 1 since always includes the directory itself
        result = {'files_saved' : files_saved}
        if files_saved > 0:

            if timestamp is None:
                # mark by the time when we actually start saving, not start indexing above.
                timestamp = int(time.time())

            result['timestamp'] = timestamp

            self.cmd(["/usr/bin/bup", "save", "--strip", "-n", self.branch, '-d', timestamp, path])

            # record this so can properly describe the true "interval of time" over which the snapshot happened,
            # in case we want to for some reason...
            result['timestamp_end'] = int(time.time())

            result['bup_repo_size_kb'] = int(self.cmd(['du', '-s', '-x', '--block-size=KB', self.bup_path]).split()[0].split('k')[0])

            if mnt and path == self.project_mnt:
                self.mount_snapshots()

            if sync:
                result['sync'] = self.sync(targets=targets)

            r = dict(result)
            n = len(self.project_mnt)+1
            r['files'] = [x[n:] for x in what_changed if len(x) > n]
            open(self.save_log,'a').write(json.dumps(r)+'\n')



        return result

    def tag(self, tag, delete=False):
        """
        Tag the latest commit to master or delete a tag.
        """
        if delete:
            self.cmd(["/usr/bin/bup", "tag", "-f", "-d", tag])
        else:
            self.cmd(["/usr/bin/bup", "tag", "-f", tag, self.branch])

    def newest_snapshot(self, branch=''):
        """
        Return newest snapshot in current branch or None if there are no snapshots yet.
        """
        v = self.snapshots(branch)
        if len(v) > 0:
            return v[-1]
        else:
            return None

    def snapshots(self, branch=''):
        """
        Return list of all snapshots in date order for the given branch.
        """
        if not branch:
            branch = self.branch
        if not os.path.exists(os.path.join(self.bup_path, 'refs', 'heads', branch)):
            # branch doesn't exist
            return []
        else:
            return self.cmd(["/usr/bin/bup", "ls", branch+'/'], verbose=0).split()[:-1]

    def branches(self):
        return {'branches':self.cmd("bup ls").split(), 'branch':self.branch}

    def cleanup(self):
        """
        Clean up the bup repo, replacing the large number of git pack files by a small number, deleting
        the bupindex cache, which can get really big, etc.

        After using this, you *must* do a destructive sync to all replicas!
        """
        self.cmd("cd %s; rm -f bupindex; rm -f objects/pack/*.midx; rm -f objects/pack/*.midx.tmp && rm -rf objects/*tmp && time git repack -lad"%self.bup_path)

    def makedirs(self, path):
        log = self._log('makedirs')
        if os.path.exists(path) and not os.path.isdir(path):
            log("removing %s"%path)
            os.unlink(path)
        if not os.path.exists(path):
            log("creating %s"%path)
            os.makedirs(path, mode=0700)
        if USERNAME == "root":
            os.chown(path, self.uid, self.gid)

    def update_daemon_code(self):
        log = self._log('update_daemon_code')
        self.create_home()
        target = '/%s/.sagemathcloud/'%self.project_mnt
        self.makedirs(target)
        self.cmd(["rsync", "-zaxHL", "--update", SAGEMATHCLOUD_TEMPLATE+"/", target])
        self.chown(target)

    def chown(self, path):
        self.cmd(["chown", "%s:%s"%(self.uid, self.gid), '-R', path])

    def ensure_file_exists(self, src, target):
        target = os.path.abspath(target)
        if not os.path.exists(target):
            self.makedirs(os.path.split(target)[0])
            shutil.copyfile(src, target)
            if USERNAME == "root":
                os.chown(target, self.uid, self.gid)

    def ensure_conf_files(self):
        log = self._log('ensure_conf_files')
        log("ensure there is a bashrc and bash_profile")
        self.create_home()
        self.ensure_file_exists(BASHRC_TEMPLATE, os.path.join(self.project_mnt,".bashrc"))
        self.ensure_file_exists(BASH_PROFILE_TEMPLATE, os.path.join(self.project_mnt,".bash_profile"))

    def xxx_ensure_ssh_access(self):  # not used!
        log = self._log('ensure_ssh_access')
        log("make sure .ssh/authorized_keys file good")
        dot_ssh = os.path.join(self.project_mnt, '.ssh')
        self.makedirs(dot_ssh)
        target = os.path.join(dot_ssh, 'authorized_keys')
        authorized_keys = '\n' + open(SSH_ACCESS_PUBLIC_KEY).read() + '\n'

        if not os.path.exists(target) or authorized_keys not in open(target).read():
            log("writing authorized_keys files")
            open(target,'w').write(authorized_keys)
        else:
            log("%s already exists and is good"%target)
        self.cmd(['chown', '-R', '%s:%s'%(self.uid, self.gid), dot_ssh])
        self.cmd(['chmod', 'og-rwx', '-R', dot_ssh])

    def get_settings(self):
        if not os.path.exists(self.conf_path):
            os.makedirs(self.conf_path)
        if os.path.exists(self.settings_path):
            try:
                settings = json.loads(open(self.settings_path).read())
                for k, v in DEFAULT_SETTINGS.iteritems():
                    if k not in settings:
                        settings[k] = v
            except (ValueError, IOError), mesg:
                settings = dict(DEFAULT_SETTINGS)
        else:
            settings = dict(DEFAULT_SETTINGS)
        return settings

    def set_quota(self, disk, scratch):

        # Disk space quota

        if FILESYSTEM == 'zfs':
            """
            zpool create -f bup XXXXX /dev/vdb
            zfs create bup/projects
            zfs set mountpoint=/projects bup/projects
            zfs set dedup=on bup/projects
            zfs set compression=lz4 bup/projects
            zfs create bup/bups
            zfs set mountpoint=/bup/bups bup/bups
            chmod og-rwx /bup/bups

            zfs create bup/scratch
            zfs set mountpoint=/scratch bup/scratch
            chmod a+rwx /scratch

            zfs create bup/conf
            zfs set mountpoint=/bup/conf bup/conf
            chmod og-rwx /bup/conf
            chown salvus. /bup/conf
            """
            cmd(['zfs', 'set', 'userquota@%s=%sM'%(self.uid, disk), '%s/projects'%ZPOOL])
            cmd(['zfs', 'set', 'userquota@%s=%sM'%(self.uid, scratch), '%s/scratch'%ZPOOL])

        """
        elif FILESYSTEM == 'ext4':

            #    filesystem options: usrquota,grpquota; then
            #    sudo su
            #    mount -o remount /; quotacheck -vugm /dev/mapper/ubuntu--vg-root -F vfsv1; quotaon -av
            disk_soft  = int(0.8*disk * 1024)   # assuming block size of 1024 (?)
            disk_hard  = disk * 1024
            inode_soft = inode
            inode_hard = 2*inode_soft
            cmd(["setquota", '-u', self.username, str(disk_soft), str(disk_hard), str(inode_soft), str(inode_hard), '-a'])
        """


    def unset_quota(self):
        cmd(['zfs', 'set', 'userquota@%s=none'%self.uid, '%s/projects'%ZPOOL])
        cmd(['zfs', 'set', 'userquota@%s=none'%self.uid, '%s/scratch'%ZPOOL])


    def settings(self, memory=None, cpu_shares=None, cores=None, disk=None,
                         inode=None, login_shell=None, scratch=None, mintime=None):
        log = self._log('settings')
        log("configuring account...")

        settings = self.get_settings()

        if memory is not None:
            settings['memory'] = int(memory)
        else:
            memory = settings['memory']
        if cpu_shares is not None:
            settings['cpu_shares'] = int(cpu_shares)
        else:
            cpu_shares = settings['cpu_shares']
        if cores is not None:
            settings['cores'] = float(cores)
        else:
            cores = settings['cores']
        if disk is not None:
            settings['disk'] = int(disk)
        else:
            disk = settings['disk']
        if scratch is not None:
            settings['scratch'] = int(scratch)
        else:
            scratch = settings['scratch']
        if inode is not None:
            settings['inode'] = int(inode)
        else:
            inode = settings['inode']

        if mintime is not None:
            settings['mintime'] = int(mintime)
        else:
            mintime= settings['mintime']

        if login_shell is not None and os.path.exists(login_shell):
            settings['login_shell'] = login_shell
        else:
            login_shell = settings['login_shell']

        try:
            s = json.dumps(settings)
            open(self.settings_path,'w').write(s)
            print s
        except IOError:
            pass

        # Set the quota
        self.set_quota(disk=disk, scratch=scratch)

        # Cgroups
        if cores <= 0:
            cfs_quota = -1  # no limit
        else:
            cfs_quota = int(100000*cores)

        self.cmd(["cgcreate", "-g", "memory,cpu:%s"%self.username])
        open("/sys/fs/cgroup/memory/%s/memory.limit_in_bytes"%self.username,'w').write("%sG"%memory)
        open("/sys/fs/cgroup/cpu/%s/cpu.shares"%self.username,'w').write(str(cpu_shares))
        open("/sys/fs/cgroup/cpu/%s/cpu.cfs_quota_us"%self.username,'w').write(str(cfs_quota))

        z = "\n%s  cpu,memory  %s\n"%(self.username, self.username)
        cur = open("/etc/cgrules.conf").read() if os.path.exists("/etc/cgrules.conf") else ''

        if z not in cur:
            open("/etc/cgrules.conf",'a').write(z)
            try:
                self.cmd(['service', 'cgred', 'restart'])
            except:
                # cgroup quota service not supported
                pass
            try:
                pids = self.cmd("ps -o pid -u %s"%self.username, ignore_errors=False).split()[1:]
                self.cmd(["cgclassify"] + pids, ignore_errors=True)
                # ignore cgclassify errors, since processes come and go, etc.":
            except:
                # ps returns an error code if there are NO processes at all (a common condition).
                pids = []

    def sync(self, targets="", replication_factor=REPLICATION_FACTOR, destructive=False, snapshots=True):
        log = self._log('sync')
        status = [{'host':h} for h in targets.split(',')]
        if not targets:
            log("nothing to sync to")
            return status
        log("syncing to %s"%targets)

        for s in status:
            t = time.time()
            try:
                self._sync(remote=s['host'], destructive=destructive, snapshots=snapshots)
            except Exception, err:
                s['error'] = str(err)
            s['time'] = time.time() - t
        return status

    def _sync(self, remote, destructive=False, snapshots=True, rsync_timeout=30):
        """
        NOTE: sync is *always* destructive on live files; on snapshots it isn't by default.

        If destructive is true, simply push from local to remote, overwriting anything that is remote.
        If destructive is false, pushes, then pulls, and makes a tag pointing at conflicts.
        """
        # NOTE: In the rsync's below we compress-in-transit the live project mount (-z),
        # but *NOT* the bup's, since they are already compressed.

        log = self._log('sync')
        log("syncing...")

        remote_bup_path = os.path.join(BUP_PATH, self.project_id)

        if os.path.exists(self.project_mnt):
            def f(ignore_errors):
                return self.cmd(["rsync", "-zaxH", '--timeout', rsync_timeout, "--delete", "--ignore-errors"] + self.exclude('') +
                          ['-e', 'ssh -o StrictHostKeyChecking=no',
                          self.project_mnt+'/', "root@%s:%s/"%(remote, self.project_mnt)], ignore_errors=ignore_errors)

            e = f(ignore_errors=True)
            if 'Disk quota exceeded' in e:
                self.cmd(["ssh", "-o", "StrictHostKeyChecking=no", 'root@'+remote,
                          'zfs set userquota@%s=%sM %s/projects'%(
                                        self.uid, self.get_settings()['disk'], ZPOOL)])
                f(ignore_errors=False)
            elif 'ERROR' in e:
                raise RuntimeError(e)

        if not snapshots:
            # nothing further to do -- we already sync'd the live files above, if we have any
            return

        if destructive:
            log("push so that remote=local: easier; have to do this after a recompact (say)")
            self.cmd(["rsync", "-axH", "--delete", '--timeout', rsync_timeout, "-e", 'ssh -o StrictHostKeyChecking=no',
                      self.bup_path+'/', "root@%s:%s/"%(remote, remote_bup_path)])
            return

        log("get remote heads")
        out = self.cmd(["ssh", "-o", "StrictHostKeyChecking=no", 'root@'+remote,
                        'grep -H \"\" %s/refs/heads/*'%remote_bup_path], ignore_errors=True)
        if 'such file or directory' in out:
            remote_heads = []
        else:
            if 'ERROR' in out:
                raise RuntimeError(out)
            remote_heads = []
            for x in out.splitlines():
                a, b = x.split(':')[-2:]
                remote_heads.append((os.path.split(a)[-1], b))
        log("sync from local to remote")
        self.cmd(["rsync", "-axH", "-e", 'ssh -o StrictHostKeyChecking=no', '--timeout', rsync_timeout,
                  self.bup_path + '/', "root@%s:%s/"%(remote, remote_bup_path)])
        log("sync from remote back to local")
        # the -v is important below!
        back = self.cmd(["rsync", "-axH", "-e", 'ssh -o StrictHostKeyChecking=no', '--timeout', rsync_timeout,
                         "root@%s:%s/"%(remote, remote_bup_path), self.bup_path + "/"]).splitlines()
        if remote_heads and len([x for x in back if x.endswith('.pack')]) > 0:
            log("there were remote packs possibly not available locally, so make tags that points to them")
            # so user can get their files if anything important got overwritten.
            tag = None
            for branch, id in remote_heads:
                # have we ever seen this commit?
                c = "%s/logs/refs/heads/%s"%(self.bup_path,branch)
                if not os.path.exists(c) or id not in open(c).read():
                    log("nope, never seen %s -- tag it."%branch)
                    tag = 'conflict-%s-%s'%(branch, time.strftime("%Y-%m-%d-%H%M%S"))
                    path = os.path.join(self.bup_path, 'refs', 'tags', tag)
                    open(path,'w').write(id)
            if tag is not None:
                log("sync back any tags")
                self.cmd(["rsync", "-axH", "-e", 'ssh -o StrictHostKeyChecking=no',
                          '--timeout', rsync_timeout, self.bup_path+'/', 'root@'+remote+'/'])

    def migrate_all(self, max_snaps=100):
        log = self._log('migrate_all')
        log("determining snapshots...")
        self.init()
        snap_path  = "/projects/%s/.zfs/snapshot"%self.project_id
        known = set([time.mktime(time.strptime(s, "%Y-%m-%d-%H%M%S")) for s in self.snapshots()])
        v = sorted(os.listdir(snap_path))
        if len(v) > max_snaps:
            trim = math.ceil(len(v)/max_snaps)
            w = [v[i] for i in range(len(v)) if i%trim==0]
            for i in range(1,5):
                if w[-i] != v[-i]:
                    w.append(v[-i])
            v = w

        v = [snapshot for snapshot in v if snapshot not in known]
        for i, snapshot in enumerate(v):
            print "**** %s/%s ****"%(i+1,len(v))
            tm = time.mktime(time.strptime(snapshot, "%Y-%m-%dT%H:%M:%S"))
            self.save(path=os.path.join(snap_path, snapshot), timestamp=tm)

        # migrate is assumed to only ever happen when we haven't been live pushing the project into the replication system.
        self.cleanup()

    def migrate_remote(self, host, targets):
        log = self._log('migrate_remote')
        self.init()
        project_mnt = '/projects/%s'%self.project_id
        t = time.time()
        log("check if remote is mounted")

        if 'sagemathcloud' not in self.cmd("ssh -o StrictHostKeyChecking=no root@%s 'ls -la %s/'"%(host, project_mnt), verbose=1, ignore_errors=True):
            # try to mount and try again
            self.cmd("ssh -o StrictHostKeyChecking=no  root@%s 'zfs set mountpoint=/projects/%s projects/%s; zfs mount projects/%s'"%(
                   host, self.project_id, self.project_id, self.project_id), ignore_errors=True, timeout=180)
            if 'sagemathcloud' not in self.cmd("ssh -o StrictHostKeyChecking=no root@%s 'ls -la %s/'"%(host, project_mnt), verbose=1, ignore_errors=True):
                print "FAIL -- unable to mount"
                return
        log("time to mount %s"%(time.time()-t))
 
        log("rsync from remote to local")
        t = time.time()
        x = self.cmd("rsync -Haxq --ignore-errors --delete %s root@%s:%s/ %s/"%(
               ' '.join(self.exclude(project_mnt+"/")), host, project_mnt, self.project_mnt), ignore_errors=True)
        log("time to rsync=%s"%(time.time()-t))
        for a in x.splitlines():
            # allow these errors only -- e.g., sshfs mounts cause them
            if 'ERROR' not in a and 'see previous errors' not in a and 'failed: Permission denied' not in a and 'Command exited with non-zero status' not in a:
                print a
                print "FAIL"
                return

        log("save local copy to local repo")
        t = time.time()
        self.save(sync=False, mnt=False)
        log("time to save=%s"%(time.time()-t))
        log("sync out")
        t = time.time()
        status = self.sync(targets=targets, destructive=True)
        log("time to sync=%s"%(time.time()-t))
        print str(status)
        for r in status:
            if r.get('error', False):
                print "FAIL"
                return False
        print "SUCCESS"
        return True

    def xxx_migrate_remote(self, host, lastmod, max_snaps=10):
        log = self._log('migrate_remote')

        live_path = "/projects/%s/"%self.project_id
        snap_path  = os.path.join(live_path, '.zfs/snapshot/')

        log("is it an abusive bitcoin miner?")
        x = self.cmd("bup ls master/latest/", verbose=1, ignore_errors=True)  # will fail if nothing local
        if 'minerd' in x or 'coin' in x:
            log("ABUSE")
            print "ABUSE"
            # nothing more to do
            return

        def sync_out():
            status = self.sync(replication_factor=REPLICATION_FACTOR, destructive=True, snapshots=True)
            print str(status)
            for r in status:
                if r.get('error', False):
                    print "FAIL"
                    return False
            return True

        log("get list of local snapshots")
        try:
            local_snapshots = self.cmd("bup ls master/", verbose=1).split()[:-1]
        except:
            local_snapshots = []
        local_snapshots.sort()
        local_snapshot_times = [time.mktime(time.strptime(s, "%Y-%m-%d-%H%M%S")) for s in local_snapshots]

        if len(local_snapshots) == 0:
            newest_local = 0
        else:
            newest_local = local_snapshot_times[-1]

        log("newest_local=%s, lastmod=%s"%(newest_local, lastmod))
        if newest_local+3 >= lastmod:  # 3 seconds due to rounding...
            sync_out()
            print "SUCCESS"
            return

        x = self.cmd("ssh -o StrictHostKeyChecking=no root@%s 'ls %s/'"%(host, live_path), ignore_errors=True, verbose=1)
        if 'minerd' in x or 'coin' in x:
            log("ABUSE")
            print "ABUSE"
            # nothing more to do
            return

        log("maybe they are not a bitcoin miner after all...")
        if not os.path.exists(self.bup_path):
            self.cmd(['/usr/bin/bup', 'init'])

        log("get list of remote snapshots")
        x = self.cmd("ssh -o StrictHostKeyChecking=no root@%s 'ls -1 %s/'"%(host, snap_path), verbose=1, ignore_errors=True)
        if 'No such file or' in x:
            # try to mount and try again
            self.cmd("ssh -o StrictHostKeyChecking=no  root@%s 'zfs set mountpoint=/projects/%s projects/%s; zfs mount projects/%s'"%(
                   host, self.project_id, self.project_id, self.project_id), ignore_errors=True, timeout=600)
            x = self.cmd("ssh -o StrictHostKeyChecking=no root@%s 'ls -1 %s/'"%(host, snap_path), verbose=1, ignore_errors=False)
        remote_snapshots = x.splitlines()
        remote_snapshots.sort()

        log("do we need to do anything?")
        if len(remote_snapshots) == 0:
            # this shouldn't come up, but well...
            print "SUCCESS"
            return
        remote_snapshot_times = [time.mktime(time.strptime(s, "%Y-%m-%dT%H:%M:%S")) for s in remote_snapshots]
        newest_remote = remote_snapshot_times[-1]


        if newest_remote < newest_local:
            log("nothing more to do -- we have enough")
            if sync_out():
                print "SUCCESS"
            return

        log("get some more snapshots")
        # v = indices into remote_snapshots list of the snapshots we need
        v = [i for i in range(len(remote_snapshots)) if remote_snapshot_times[i] not in local_snapshot_times]

        if len(v) > max_snaps:
            log('shrinking list to save time')
            trim = math.ceil(len(v)/max_snaps)
            w = [v[i] for i in range(len(v)) if i%trim==0]
            for i in range(1,5):
                if w[-i] != v[-i]:
                    w.append(v[-i])
            v = w

        log("in fact, get %s more snapshots"%len(v))

        just_get_home = False
        for i in v:
            path = os.path.join(snap_path, remote_snapshots[i])
            tm   = remote_snapshot_times[i]

            try:
                self.cmd(["/usr/bin/bup", "on", 'root@'+host, "index", "-x"] + self.exclude(path+'/') + [path],
                         timeout=600)
            except:
                just_get_home = True
                break
            self.cmd(["/usr/bin/bup", "on", 'root@'+host, "save", "--strip", "-n", 'master', '-d', tm, path])

        if just_get_home:
            log("problems indexing zfs snapshots -- so just get a copy of the live filesystem")
            self.cmd(["/usr/bin/bup", "on", 'root@'+host, "index", "-x"] + self.exclude(live_path+'/') + [live_path], ignore_errors=True)
            self.cmd(["/usr/bin/bup", "on", 'root@'+host, "save", "--strip", "-n", 'master', live_path])

        if len(v) > 5:
           log("doing a cleanup too, so we start fresh")
           self.cleanup()

        if sync_out():
            print "SUCCESS"




if __name__ == "__main__":

    parser = argparse.ArgumentParser(description="Bup-backed SMC project storage system")
    subparsers = parser.add_subparsers(help='sub-command help')

    parser.add_argument("project_id", help="project id -- most subcommand require this", type=str)

    parser_init = subparsers.add_parser('init', help='init project repo and directory')
    parser_init.set_defaults(func=lambda args: project.init())

    parser_start = subparsers.add_parser('start', help='create user and setup the ~/.sagemathcloud filesystem')
    parser_start.set_defaults(func=lambda args: project.start())

    parser_status = subparsers.add_parser('status', help='get status of servers running in the project')
    def print_status():
        print json.dumps(project.status())
    parser_status.set_defaults(func=lambda args: print_status())

    parser_stop = subparsers.add_parser('stop', help='Kill all processes running as this user and delete user.')
    parser_stop.add_argument("--only_if_idle", help="only actually stop the project if the project is idle long enough",
                                   dest="only_if_idle", default=False, action="store_const", const=True)
    parser_stop.set_defaults(func=lambda args: project.stop(only_if_idle=args.only_if_idle))

    parser_restart = subparsers.add_parser('restart', help='restart servers')
    parser_restart.set_defaults(func=lambda args: project.restart())

    def do_save(*args, **kwds):
        print json.dumps(project.save(*args, **kwds))
    parser_save = subparsers.add_parser('save', help='save a snapshot then sync everything out')
    parser_save.add_argument("--targets", help="if given, a comma separated ip addresses of computers to replicate to NOT including the current machine", dest="targets", default="", type=str)
    parser_save.add_argument("--branch", dest="branch", help="save to specified branch (default: whatever current branch is); will change to that branch if different", type=str, default='')
    parser_save.set_defaults(func=lambda args: do_save(branch=args.branch, targets=args.targets))

    def do_sync(*args, **kwds):
        status = project.sync(*args, **kwds)
        print json.dumps(status)
    parser_sync = subparsers.add_parser('sync', help='sync with all replicas')
    parser_sync.add_argument("--targets", help="if given, a comma separated ip addresses of computers to replicate to NOT including the current machine", dest="targets", default="", type=str)
    parser_sync.add_argument("--replication_factor", help="number of replicas to sync with in each data center or [2,1,3]=2 in dc0, 1 in dc1, etc. (default: %s)"%REPLICATION_FACTOR,
                                   dest="replication_factor", default=REPLICATION_FACTOR, type=int)
    parser_sync.add_argument("--destructive", help="sync, destructively overwriting all remote replicas (DANGEROUS)",
                                   dest="destructive", default=False, action="store_const", const=True)
    parser_sync.add_argument("--snapshots", help="include snapshots in sync",
                                   dest="snapshots", default=False, action="store_const", const=True)
    parser_sync.set_defaults(func=lambda args: do_sync(targets            = args.targets,
                                                       replication_factor = args.replication_factor,
                                                       destructive        = args.destructive,
                                                       snapshots          = args.snapshots))

    parser_settings = subparsers.add_parser('settings', help='set settings for this user; also outputs settings in JSON')
    parser_settings.add_argument("--memory", dest="memory", help="memory settings in gigabytes",
                               type=int, default=None)
    parser_settings.add_argument("--cpu_shares", dest="cpu_shares", help="shares of the cpu",
                               type=int, default=None)
    parser_settings.add_argument("--cores", dest="cores", help="max number of cores (may be float)",
                               type=float, default=None)
    parser_settings.add_argument("--disk", dest="disk", help="working disk space in megabytes", type=int, default=None)
    parser_settings.add_argument("--mintime", dest="mintime", help="minimum time in seconds before this project is automatically stopped if not saved", type=int, default=None)
    parser_settings.add_argument("--scratch", dest="scratch", help="scratch disk space in megabytes", type=int, default=None)
    parser_settings.add_argument("--inode", dest="inode", help="inode settings", type=int, default=None)
    parser_settings.add_argument("--login_shell", dest="login_shell", help="the login shell used when creating user", default=None, type=str)
    parser_settings.set_defaults(func=lambda args: project.settings(
                    memory=args.memory, cpu_shares=args.cpu_shares,
                    cores=args.cores, disk=args.disk, inode=args.inode, scratch=args.scratch,
                    login_shell=args.login_shell, mintime=args.mintime))

    parser_tag = subparsers.add_parser('tag', help='tag the *latest* commit to master, or delete a tag')
    parser_tag.add_argument("tag", help="tag name", type=str)
    parser_tag.add_argument("--delete", help="delete the given tag",
                                   dest="delete", default=False, action="store_const", const=True)
    parser_tag.set_defaults(func=lambda args: project.tag(tag=args.tag, delete=args.delete))


    if UNSAFE_MODE:
        parser_archive = subparsers.add_parser('archive', help="*DANGEROUS*: Remove the user's files, leaving only the bup repo.")
        parser_archive.set_defaults(func=lambda args: project.archive())

        parser_destroy = subparsers.add_parser('destroy', help='**DANGEROUS**: Delete all traces of this project from this machine.')
        parser_destroy.set_defaults(func=lambda args: project.destroy())

    parser_snapshots = subparsers.add_parser('snapshots', help='output JSON list of snapshots of current branch')
    parser_snapshots.add_argument("--branch", dest="branch", help="show for given branch (by default the current one)", type=str, default='')
    parser_snapshots.set_defaults(func=lambda args: print_json(project.snapshots(branch=args.branch)))

    parser_branches = subparsers.add_parser('branches', help='output JSON {branches:[list of branches], branch:"name"}')
    parser_branches.set_defaults(func=lambda args: print_json(project.branches()))

    parser_checkout = subparsers.add_parser('checkout', help='checkout snapshot of project to working directory (DANGEROUS)')
    parser_checkout.add_argument("--snapshot", dest="snapshot", help="which tag or snapshot to checkout (default: latest)", type=str, default='latest')
    parser_checkout.add_argument("--branch", dest="branch", help="branch to checkout (default: whatever current branch is)", type=str, default='')
    parser_checkout.set_defaults(func=lambda args: project.checkout(snapshot=args.snapshot, branch=args.branch))

    parser_migrate_all = subparsers.add_parser('migrate_all', help='migrate all snapshots of project from old ZFS format')
    parser_migrate_all.set_defaults(func=lambda args: project.migrate_all())

    parser_migrate_remote = subparsers.add_parser('migrate_remote', help='final migration')
    parser_migrate_remote.add_argument("host", help="where migrating from", type=str)
    parser_migrate_remote.add_argument("--targets", help="comma separated ip addresses of computers to replicate to NOT including the current machine", dest="targets", default="", type=str)
    parser_migrate_remote.set_defaults(func=lambda args: project.migrate_remote(host=args.host, targets=args.targets))

    args = parser.parse_args()

    t0 = time.time()
    project = Project(project_id  = args.project_id)
    args.func(args)
    log("total time: %s seconds"%(time.time()-t0))
