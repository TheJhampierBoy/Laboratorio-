package com.sena.laboratorio.service;

import com.sena.laboratorio.model.Usuario;
import com.sena.laboratorio.repository.UsuarioRepository;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.stereotype.Service;

import java.util.List;
import java.util.Optional;

@Service
public class UsuarioService {

    @Autowired
    private UsuarioRepository usuarioRepository;

    public List<Usuario> listarTodos() {
        return usuarioRepository.findAll();
    }

    public Optional<Usuario> buscarPorId(Long id) {
        return usuarioRepository.findById(id);
    }

    public Usuario guardar(Usuario usuario) {
        return usuarioRepository.save(usuario);
    }

    public Usuario actualizar(Long id, Usuario usuario) {
        return usuarioRepository.findById(id)
                .map(usuarioExistente -> {
                    usuarioExistente.setNombre(usuario.getNombre());
                    usuarioExistente.setCorreo(usuario.getCorreo());
                    usuarioExistente.setTelefono(usuario.getTelefono());
                    usuarioExistente.setFechaNacimiento(usuario.getFechaNacimiento());
                    usuarioExistente.setCiudad(usuario.getCiudad());
                    return usuarioRepository.save(usuarioExistente);
                })
                .orElseThrow(() -> new RuntimeException("Usuario no encontrado con id: " + id));
    }

    public void eliminar(Long id) {
        usuarioRepository.deleteById(id);
    }
}
